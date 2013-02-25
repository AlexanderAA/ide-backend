{-# LANGUAGE TypeSynonymInstances, FlexibleInstances, MultiParamTypeClasses, GeneralizedNewtypeDeriving, TemplateHaskell, CPP #-}
module GhcHsWalk
  ( IdMap(..)
  , IdInfo(..)
  , IdNameSpace(..)
  , IsBinder(..)
  , extractIdsPlugin
  , haddockLink
  , idInfoAtLocation
  ) where

import Prelude hiding (span, id, mod)
import Control.Monad (forM_)
import Control.Monad.Writer (MonadWriter, WriterT, execWriterT, tell, censor)
import Control.Monad.Reader (MonadReader, ReaderT, runReaderT, ask)
import Control.Monad.Trans.Class (MonadTrans, lift)
import Data.IORef
import System.FilePath (takeFileName)
import Data.Aeson (FromJSON(..), ToJSON(..))
import Data.Aeson.TH (deriveJSON)
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Maybe (fromMaybe)
import Data.Monoid

import Common
import GhcRun (extractSourceSpan)

import GHC hiding (idType)
import TcRnTypes
import Outputable
import HscPlugin
import Var hiding (idInfo)
import qualified Name as Name
import qualified Module as Module
import MonadUtils (MonadIO(..))
import Bag
import DataCon (dataConName)

#define DEBUG 1

{------------------------------------------------------------------------------
  TODO: Current known problems:

  - RECORDS

    Given

    > data T = MkT { a :: Bool, b :: Int }
    > someT = MkT { a = True, b = 5 }

    the record declaration does not have any source info at all for MkT, a or b;
    the record definition as 'a' point to the record definition rather than the
    record declaration.
------------------------------------------------------------------------------}


{------------------------------------------------------------------------------
  Environment mapping source locations to info
------------------------------------------------------------------------------}

-- This type is abstract in GHC. One more reason to define our own.
data IdNameSpace =
    VarName    -- ^ Variables, including real data constructors
  | DataName   -- ^ Source data constructors
  | TvName     -- ^ Type variables
  | TcClsName  -- ^ Type constructors and classes
  deriving (Show, Eq)

data IsBinder = Binding | NonBinding
  deriving (Show, Eq)

-- | Information about identifiers
data IdInfo = IdInfo
  { -- | The base name of the identifer at this location. Module prefix
    -- is not included.
    idName :: String
    -- | The module prefix of the identifier. Empty, if a local variable.
  , idModule :: Maybe String
    -- | Package the identifier comes from. Empty, if a local variable.
  , idPackage :: Maybe String
    -- | Namespace of the identifier.
  , idSpace :: IdNameSpace
    -- | The type
    -- We don't always know this; in particular, we don't know kinds because
    -- the type checker does not give us LSigs for top-level annotations)
  , idType :: Maybe String
    -- | Where was this identifier defined?
  , idDefSpan :: EitherSpan
    -- | Is this a binding occurrence?
  , idIsBinder :: IsBinder
  }
  deriving (Show, Eq)

data IdMap = IdMap { idMapToMap :: Map SourceSpan IdInfo }

$(deriveJSON (\x -> x) ''IdNameSpace)
$(deriveJSON (\x -> x) ''IsBinder)
$(deriveJSON (\x -> x) ''IdInfo)

instance FromJSON IdMap where
  parseJSON = fmap (IdMap . Map.fromList) . parseJSON

instance ToJSON IdMap where
  toJSON = toJSON . Map.toList . idMapToMap

idMapToList :: IdMap -> [(SourceSpan, IdInfo)]
idMapToList = Map.toList . idMapToMap

instance Show IdMap where
  show = unlines . map pp . idMapToList
    where
      ppDash n m | m - n <= 1 = show n
                 | otherwise = show n ++ "-" ++ show (m - 1)
      ppSpan (SourceSpan fn stL stC endL endC) =
        fn ++ ":" ++ ppDash stL endL ++ ":" ++ ppDash stC endC
      ppEitherSpan (ProperSpan sp) = ppSpan sp
      ppEitherSpan (TextSpan s) = s

      pp (sp, IdInfo{..}) =
        takeFileName (ppSpan sp)
        ++ " (" ++ show idSpace
        ++ (case idIsBinder of Binding -> ", binder): " ; _ -> "): ")
        ++ maybe "" (++ "/") idPackage
        ++ maybe "" (++ ".") idModule
        ++ idName ++ " :: "
        ++ (case idType of Nothing -> "<unknown type>" ; Just tp -> tp)
        ++ " (" ++ takeFileName (ppEitherSpan idDefSpan) ++ ")"

-- Right-biased union (information provided by the type checker replaces
-- information provided by the renamer)
instance Monoid IdMap where
  mempty = IdMap Map.empty
  (IdMap a) `mappend` (IdMap b) = IdMap (Map.union b a)

fromGhcNameSpace :: Name.NameSpace -> IdNameSpace
fromGhcNameSpace ns =
  if ns == Name.varName then VarName
  else if ns == Name.dataName then DataName
  else if ns == Name.tvName then TvName
  else if ns == Name.tcName then TcClsName
  else error "fromGhcNameSpace"

-- | Show approximately what Haddock adds to documantation URLs.
haddockSpaceMarks :: IdNameSpace -> String
haddockSpaceMarks VarName = "v"
haddockSpaceMarks DataName = "v"
haddockSpaceMarks TvName = "t"
haddockSpaceMarks TcClsName = "t"

-- | Show approximately a haddock link (without haddock root) for an id.
-- This is an illustraction and a test of the id info, but under ideal
-- conditions could perhaps serve to link to documentation without
-- going via Hoogle.
haddockLink :: IdInfo -> String
haddockLink IdInfo{..} =
      fromMaybe "<unknown package>" idPackage ++ "/"
   ++ maybe "<unknown module>" dotToDash idModule ++ ".html#"
   ++ haddockSpaceMarks idSpace ++ ":"
   ++ idName
 where
   dotToDash = map (\c -> if c == '.' then '-' else c)

idInfoAtLocation :: Int -> Int -> IdMap -> [IdInfo]
idInfoAtLocation line col = map snd . filter inRange . idMapToList
  where
    inRange :: (SourceSpan, a) -> Bool
    inRange (SourceSpan{..}, _) =
      (line   > spanFromLine || (line == spanFromLine && col >= spanFromColumn)) &&
      (line   < spanToLine   || (line == spanToLine   && col <= spanToColumn))

{------------------------------------------------------------------------------
  Extract an IdMap from information returned by the ghc type checker
------------------------------------------------------------------------------}

extractIdsPlugin :: IORef [IdMap] -> HscPlugin
extractIdsPlugin symbolRef = HscPlugin $ \dynFlags env -> do
  identMap <- execExtractIdsT dynFlags $ do extractIds (tcg_rn_decls env)
                                            extractIds (tcg_binds env)
  liftIO $ modifyIORef symbolRef (identMap :)
  return env

{------------------------------------------------------------------------------
  ExtractIdsT is just a wrapper around the writer monad for IdMap
  (we wrap it to avoid orphan instances). Note that MonadIO is GHC's
  MonadIO, not the standard one, and hence we need our own instance.
------------------------------------------------------------------------------}

-- Define type synonym to avoid orphan instances
newtype ExtractIdsT m a = ExtractIdsT {
      runExtractIdsT :: ReaderT DynFlags (WriterT IdMap m) a
    }
  deriving (Functor, Monad, MonadWriter IdMap, MonadReader DynFlags)

execExtractIdsT :: Monad m => DynFlags -> ExtractIdsT m () -> m IdMap
execExtractIdsT dynFlags m = execWriterT (runReaderT (runExtractIdsT m) dynFlags)

instance MonadTrans ExtractIdsT where
  lift = ExtractIdsT . lift . lift

-- This is not the standard MonadIO, but the MonadIO from GHC!
instance MonadIO m => MonadIO (ExtractIdsT m) where
  liftIO = lift . liftIO

-- In ghc 7.4 showSDoc does not take the dynflags argument; for 7.6 and up
-- it does
pretty :: (Monad m, Outputable a) => a -> ExtractIdsT m String
pretty val = do
  _dynFlags <- ask
#if __GLASGOW_HASKELL__ >= 706
  return $ showSDoc _dynFlags (ppr val)
#else
  return $ showSDoc (ppr val)
#endif

debugPP :: (MonadIO m, Outputable a) => String -> a -> ExtractIdsT m ()
debugPP header val = do
  val' <- pretty val
  liftIO $ appendFile "/tmp/ghc.log" (header ++ ": " ++ val' ++ "\n")

record :: (MonadIO m, ConstructIdInfo id)
       => SrcSpan -> IsBinder -> id -> ExtractIdsT m ()
record span isBinder id = do
  case extractSourceSpan span of
    ProperSpan sourceSpan -> do
      idInfo <- constructIdInfo isBinder id
      tell . IdMap $ Map.singleton sourceSpan idInfo
    TextSpan _ ->
      debugPP "Id without source span" id

-- For debugging purposes, we also record information about the AST
ast :: Monad m => SrcSpan -> String -> ExtractIdsT m a -> ExtractIdsT m a
#if DEBUG
ast span info cont = do
  let idInfo = IdInfo { idName     = info
                      , idModule   = Nothing
                      , idPackage  = Nothing
                      , idSpace    = VarName
                      , idType     = Nothing
                      , idDefSpan  = TextSpan "<Debugging>"
                      , idIsBinder = NonBinding
                      }
  case extractSourceSpan span of
    ProperSpan sourceSpan -> do
      tell . IdMap $ Map.singleton sourceSpan idInfo
      censor addInfo cont
    TextSpan _ ->
      censor addInfo cont
  where
    addInfo :: IdMap -> IdMap
    addInfo = IdMap . Map.map addInfo' . idMapToMap

    addInfo' :: IdInfo -> IdInfo
    addInfo' idInfo =
      if idDefSpan idInfo == TextSpan "<Debugging>"
        then idInfo { idName = info ++ "/" ++ idName idInfo }
        else idInfo
#else
ast _ _ cont = cond
#endif

unsupported :: Monad m => String -> ExtractIdsT m ()
#if DEBUG
-- We should ignore unrecognized expressions rather than throw an error
-- However, for writing this code in the first place it's useful to know
-- which constructor we fail to support
unsupported c = fail $ "extractIds: unsupported " ++ c
#else
unsupported _ = return ()
#endif

{------------------------------------------------------------------------------
  ConstructIdInfo
------------------------------------------------------------------------------}

class OutputableBndr id => ConstructIdInfo id where
  constructIdInfo :: Monad m => IsBinder -> id -> ExtractIdsT m IdInfo

instance ConstructIdInfo Id where
  constructIdInfo idIsBinder id = do
    idInfo <- constructIdInfo idIsBinder (Var.varName id)
    typ    <- pretty (Var.varType id)
    return idInfo { idType = Just typ }

instance ConstructIdInfo Name where
  constructIdInfo idIsBinder name = return IdInfo{..}
    where
      occ       = Name.nameOccName name
      mod       = Name.nameModule_maybe name
      idName    = Name.occNameString occ
      idModule  = fmap (Module.moduleNameString . Module.moduleName) mod
      idPackage = fmap (Module.packageIdString . Module.modulePackageId) mod
      idSpace   = fromGhcNameSpace $ Name.occNameSpace occ
      idDefSpan = extractSourceSpan (Name.nameSrcSpan name)
      idType    = Nothing -- After renamer but before typechecker

{------------------------------------------------------------------------------
  ExtractIds
------------------------------------------------------------------------------}

class ExtractIds a where
  extractIds :: MonadIO m => a -> ExtractIdsT m ()

instance ExtractIds a => ExtractIds [a] where
  extractIds = mapM_ extractIds

instance ExtractIds a => ExtractIds (Maybe a) where
  extractIds Nothing  = return ()
  extractIds (Just x) = extractIds x

instance ConstructIdInfo id => ExtractIds (HsGroup id) where
  extractIds group = do
    -- TODO: HsGroup has lots of other fields
    extractIds (hs_valds group)

instance ConstructIdInfo id => ExtractIds (HsValBinds id) where
  extractIds (ValBindsIn {}) =
    fail "extractIds: Unexpected ValBindsIn"
  extractIds (ValBindsOut binds sigs) = do
    extractIds (map snd binds)
    extractIds sigs

instance ConstructIdInfo id => ExtractIds (LSig id) where
  extractIds (L span (TypeSig names tp)) = ast span "TypeSig" $ do
    forM_ names $ \name -> record (getLoc name) NonBinding (unLoc name)
    extractIds tp
  extractIds (L _span (GenericSig _ _)) = unsupported "GenericSig"
  extractIds (L _span (IdSig _))        = unsupported "IdSig"
  extractIds (L _span (FixSig _))       = unsupported "FixSig"
  extractIds (L _span (InlineSig _ _))  = unsupported "InlineSig"
  extractIds (L _span (SpecSig _ _ _))  = unsupported "SpecSig"
  extractIds (L _span (SpecInstSig _))  = unsupported "SpecInstSig"

instance ConstructIdInfo id => ExtractIds (LHsType id) where
  extractIds (L span (HsFunTy arg res)) = ast span "HsFunTy" $
    extractIds [arg, res]
  extractIds (L span (HsTyVar name)) = ast span "HsTyVar" $
    record span NonBinding name
  extractIds (L _span (HsForAllTy _explicitFlag tyVars _ctxt body)) = do
    extractIds tyVars
    extractIds body
  extractIds (L span (HsAppTy fun arg)) = ast span "HsAppTy" $
    extractIds [fun, arg]
  extractIds (L span (HsTupleTy _tupleSort typs)) = ast span "HsTupleTy" $
    -- tupleSort is unboxed/boxed/etc.
    extractIds typs

  extractIds (L _span (HsListTy _))            = unsupported "HsListTy"
  extractIds (L _span (HsPArrTy _))            = unsupported "HsPArrTy"
  extractIds (L _span (HsOpTy _ _ _))          = unsupported "HsOpTy"
  extractIds (L _span (HsParTy _))             = unsupported "HsParTy"
  extractIds (L _span (HsIParamTy _ _))        = unsupported "HsIParamTy"
  extractIds (L _span (HsEqTy _ _))            = unsupported "HsEqTy"
  extractIds (L _span (HsKindSig _ _))         = unsupported "HsKindSig"
  extractIds (L _span (HsQuasiQuoteTy _))      = unsupported "HsQuasiQuoteTy"
  extractIds (L _span (HsSpliceTy _ _ _))      = unsupported "HsSpliceTy"
  extractIds (L _span (HsDocTy _ _))           = unsupported "HsDocTy"
  extractIds (L _span (HsBangTy _ _))          = unsupported "HsBangTy"
  extractIds (L _span (HsRecTy _))             = unsupported "HsRecTy"
  extractIds (L _span (HsCoreTy _))            = unsupported "HsCoreTy"
  extractIds (L _span (HsExplicitListTy _ _))  = unsupported "HsExplicitListTy"
  extractIds (L _span (HsExplicitTupleTy _ _)) = unsupported "HsExplicitTupleTy"
  extractIds (L _span (HsWrapTy _ _))          = unsupported "HsWrapTy"

#if __GLASGOW_HASKELL__ >= 706
  extractIds (L _span (HsTyLit _))             = unsupported "HsTyLit"
#endif

#if __GLASGOW_HASKELL__ >= 706
instance ConstructIdInfo id => ExtractIds (LHsTyVarBndrs id) where
  extractIds (HsQTvs _kvs tvs) = do
    -- We don't have location info for the kind variables
    extractIds tvs
#endif

instance ConstructIdInfo id => ExtractIds (LHsTyVarBndr id) where
#if __GLASGOW_HASKELL__ >= 706
  extractIds (L span (UserTyVar name)) = ast span "UserTyVar" $
#else
  extractIds (L span (UserTyVar name _postTcKind)) = ast span "UserTyVar" $
#endif
    record span Binding name

#if __GLASGOW_HASKELL__ >= 706
  extractIds (L span (KindedTyVar name _kind)) = ast span "KindedTyVar" $
#else
  extractIds (L span (KindedTyVar name _kind _postTcKind)) = ast span "KindedTyVar" $
#endif
    -- TODO: deal with _kind
    record span Binding name

instance ConstructIdInfo id => ExtractIds (LHsBinds id) where
  extractIds = extractIds . bagToList

instance ConstructIdInfo id => ExtractIds (LHsBind id) where
  extractIds (L span bind@(FunBind {})) = ast span "FunBind" $ do
    record (getLoc (fun_id bind)) Binding (unLoc (fun_id bind))
    extractIds (fun_matches bind)
  extractIds (L span _bind@(PatBind {})) = ast span "PatBind" $
    unsupported "PatBind"
  extractIds (L span _bind@(VarBind {})) = ast span "VarBind" $
    unsupported "VarBind"
  extractIds (L span bind@(AbsBinds {})) = ast span "AbsBinds" $
    extractIds (abs_binds bind)

instance ConstructIdInfo id => ExtractIds (MatchGroup id) where
  extractIds (MatchGroup matches _postTcType) = do
    extractIds matches
    -- We ignore the postTcType, as it doesn't have location information

instance ConstructIdInfo id => ExtractIds (LMatch id) where
  extractIds (L span (Match pats _type rhss)) = ast span "Match" $ do
    extractIds pats
    extractIds rhss

instance ConstructIdInfo id => ExtractIds (GRHSs id) where
  extractIds (GRHSs rhss binds) = do
    extractIds rhss
    extractIds binds

instance ConstructIdInfo id => ExtractIds (LGRHS id) where
  extractIds (L span (GRHS _guards rhs)) = ast span "GRHS" $
    extractIds rhs

instance ConstructIdInfo id => ExtractIds (HsLocalBinds id) where
  extractIds EmptyLocalBinds =
    return ()
  extractIds (HsValBinds (ValBindsIn _ _)) =
    fail "extractIds: Unexpected ValBindsIn (after renamer these should not exist)"
  extractIds (HsValBinds (ValBindsOut binds sigs)) = do
    extractIds (map snd binds) -- "fst" is 'rec flag'
    extractIds sigs
  extractIds (HsIPBinds _) =
    unsupported "HsIPBinds"

instance ConstructIdInfo id => ExtractIds (LHsExpr id) where
  extractIds (L span (HsPar expr)) = ast span "HsPar" $
    extractIds expr
  extractIds (L span (ExprWithTySig expr _type)) = ast span "ExprWithTySig" $ do
    extractIds expr
    debugPP "ExprWithTySig" _type
  extractIds (L span (ExprWithTySigOut expr _type)) = ast span "ExprWithTySigOut" $ do
    extractIds expr
    debugPP "ExprWithTySig" _type
  extractIds (L span (HsOverLit _ )) = ast span "HsOverLit" $
    return ()
  extractIds (L span (OpApp left op _fix right)) = ast span "OpApp" $
    extractIds [left, op, right]
  extractIds (L span (HsVar id)) = ast span "HsVar" $
    record span NonBinding id
  extractIds (L span (HsWrap _wrapper expr)) = ast span "HsWrap" $
    extractIds (L span expr)
  extractIds (L span (HsLet binds expr)) = ast span "HsLet" $ do
    extractIds binds
    extractIds expr
  extractIds (L span (HsApp fun arg)) = ast span "HsApp" $
    extractIds [fun, arg]
  extractIds (L span (HsLit _)) = ast span "HsLit" $
    return ()
  extractIds (L span (HsLam matches)) = ast span "HsLam" $
    extractIds matches
  extractIds (L span (HsDo _ctxt stmts _postTcType)) = ast span "HsDo" $
    -- ctxt indicates what kind of statement it is; AFAICT there is no
    -- useful information in it for us
    -- postTcType is not located
    extractIds stmts
  extractIds (L span (ExplicitList _postTcType exprs)) = ast span "ExplicitList" $
    extractIds exprs
  extractIds (L span (RecordCon con _postTcType recordBinds)) = ast span "RecordCon" $ do
    record (getLoc con) NonBinding (unLoc con)
    extractIds recordBinds
  extractIds (L span (HsCase expr matches)) = ast span "HsCase" $ do
    extractIds expr
    extractIds matches

  extractIds (L _ (HsIPVar _ ))          = unsupported "HsIPVar"
  extractIds (L _ (NegApp _ _))          = unsupported "NegApp"
  extractIds (L _ (SectionL _ _))        = unsupported "SectionL"
  extractIds (L _ (SectionR _ _))        = unsupported "SectionR"
  extractIds (L _ (ExplicitTuple _ _))   = unsupported "ExplicitTuple"
  extractIds (L _ (HsIf _ _ _ _))        = unsupported "HsIf"
  extractIds (L _ (ExplicitPArr _ _))    = unsupported "ExplicitPArr"
  extractIds (L _ (RecordUpd _ _ _ _ _)) = unsupported "RecordUpd"
  extractIds (L _ (ArithSeq _ _ ))       = unsupported "ArithSeq"
  extractIds (L _ (PArrSeq _ _))         = unsupported "PArrSeq"
  extractIds (L _ (HsSCC _ _))           = unsupported "HsSCC"
  extractIds (L _ (HsCoreAnn _ _))       = unsupported "HsCoreAnn"
  extractIds (L _ (HsBracket _))         = unsupported "HsBracket"
  extractIds (L _ (HsBracketOut _ _))    = unsupported "HsBracketOut"
  extractIds (L _ (HsSpliceE _))         = unsupported "HsSpliceE"
  extractIds (L _ (HsQuasiQuoteE _ ))    = unsupported "HsQuasiQuoteE"
  extractIds (L _ (HsProc _ _))          = unsupported "HsProc"
  extractIds (L _ (HsArrApp _ _ _ _ _))  = unsupported "HsArrApp"
  extractIds (L _ (HsArrForm _ _ _))     = unsupported "HsArrForm"
  extractIds (L _ (HsTick _ _))          = unsupported "HsTick"
  extractIds (L _ (HsBinTick _ _ _))     = unsupported "HsBinTick"
  extractIds (L _ (HsTickPragma _ _))    = unsupported "HsTickPragma"
  extractIds (L _ (EWildPat))            = unsupported "EWildPat"
  extractIds (L _ (EAsPat _ _))          = unsupported "EAsPat"
  extractIds (L _ (EViewPat _ _))        = unsupported "EViewPat"
  extractIds (L _ (ELazyPat _))          = unsupported "ELazyPat"
  extractIds (L _ (HsType _ ))           = unsupported "HsType"

#if __GLASGOW_HASKELL__ >= 706
  extractIds (L _ (HsLamCase _ _ ))      = unsupported "HsLamCase"
  extractIds (L _ (HsMultiIf _ _))       = unsupported "HsMultiIf"
#endif

instance (ExtractIds a, ConstructIdInfo id) => ExtractIds (HsRecFields id a) where
  extractIds (HsRecFields rec_flds _rec_dotdot) =
    extractIds rec_flds

instance (ExtractIds a, ConstructIdInfo id) => ExtractIds (HsRecField id a) where
  extractIds (HsRecField id arg _pun) = do
    record (getLoc id) NonBinding (unLoc id)
    extractIds arg

-- The meaning of the constructors of LStmt isn't so obvious; see various
-- notes in ghc/compiler/hsSyn/HsExpr.lhs
instance ConstructIdInfo id => ExtractIds (LStmt id) where
  extractIds (L span (ExprStmt expr _seq _guard _postTcType)) = ast span "ExprStmt" $
    -- Neither _seq nor _guard are located
    extractIds expr
  extractIds (L span (BindStmt pat expr _bind _fail)) = ast span "BindStmt" $ do
    -- Neither _bind or _fail are located
    extractIds pat
    extractIds expr
  extractIds (L span (LetStmt binds)) = ast span "LetStmt" $
    extractIds binds
  extractIds (L span (LastStmt expr _return)) = ast span "LastStmt" $
    extractIds expr

  extractIds (L _span (TransStmt {}))     = unsupported "TransStmt"
  extractIds (L _span (RecStmt {}))       = unsupported "RecStmt"

#if __GLASGOW_HASKELL__ >= 706
  extractIds (L _span (ParStmt _ _ _))    = unsupported "ParStmt"
#else
  extractIds (L _span (ParStmt _ _ _ _))  = unsupported "ParStmt"
#endif

instance ConstructIdInfo id => ExtractIds (LPat id) where
  extractIds (L span (WildPat _postTcType)) = ast span "WildPat" $
    return ()
  extractIds (L span (VarPat id)) = ast span "VarPat" $
    record span Binding id
  extractIds (L span (LazyPat pat)) = ast span "LazyPat" $
    extractIds pat
  extractIds (L span (AsPat id pat)) = ast span "AsPat" $ do
    record (getLoc id) Binding (unLoc id)
    extractIds pat
  extractIds (L span (ParPat pat)) = ast span "ParPat" $
    extractIds pat
  extractIds (L span (BangPat pat)) = ast span "BangPat" $
    extractIds pat
  extractIds (L span (ListPat pats _postTcType)) = ast span "ListPat" $
    extractIds pats
  extractIds (L span (TuplePat pats _boxity _postTcType)) = ast span "TuplePat" $
    extractIds pats
  extractIds (L span (PArrPat pats _postTcType)) = ast span "PArrPat" $
    extractIds pats
  extractIds (L span (ConPatIn con details)) = ast span "ConPatIn" $ do
    record (getLoc con) NonBinding (unLoc con) -- the constructor name is non-binding
    extractIds details
  extractIds (L span (ConPatOut {pat_con, pat_args})) = ast span "ConPatOut" $ do
    record (getLoc pat_con) NonBinding (dataConName (unLoc pat_con))
    extractIds pat_args

  -- View patterns
  extractIds (L _span (ViewPat _ _ _))     = unsupported "ViewPat"
  extractIds (L _span (QuasiQuotePat _))   = unsupported "QuasiQuotePat"
  extractIds (L _span (LitPat _))          = unsupported "LitPat"
  extractIds (L _span (NPat _ _ _))        = unsupported "NPat"
  extractIds (L _span (NPlusKPat _ _ _ _)) = unsupported "NPlusKPat"
  extractIds (L _span (SigPatIn _ _))      = unsupported "SigPatIn"
  extractIds (L _span (SigPatOut _ _))     = unsupported "SigPatOut"
  extractIds (L _span (CoPat _ _ _))       = unsupported "CoPat"

instance ConstructIdInfo id => ExtractIds (HsConPatDetails id) where
  extractIds (PrefixCon args) = extractIds args
  extractIds (RecCon rec)     = extractIds rec
  extractIds (InfixCon a b)   = extractIds [a, b]


