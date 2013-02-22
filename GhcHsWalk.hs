{-# LANGUAGE TypeSynonymInstances, FlexibleInstances, MultiParamTypeClasses, GeneralizedNewtypeDeriving, TemplateHaskell #-}
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
import Control.Monad.Writer (MonadWriter, WriterT, execWriterT, tell)
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
  dynFlags <- ask
  return $ showSDoc dynFlags (ppr val)

debugPP :: (MonadIO m, Outputable a) => String -> a -> ExtractIdsT m ()
debugPP header val = do
  val' <- pretty val
  liftIO $ appendFile "/tmp/ghc.log" (header ++ ": " ++ val' ++ "\n")

record :: (Monad m, ConstructIdInfo id)
       => SrcSpan -> IsBinder -> id -> ExtractIdsT m ()
record span isBinder id = do
  sourceSpan <- case extractSourceSpan span of
    ProperSpan sp -> return sp
    TextSpan unhelpful -> fail $ "Id without sourcespan: " ++ unhelpful
  idInfo <- constructIdInfo isBinder id
  tell . IdMap $ Map.singleton sourceSpan idInfo

-- We should ignore unrecognized expressions rather than throw an error
-- However, for writing this code in the first place it's useful to know
-- which constructor we fail to support
unsupported :: Monad m => String -> ExtractIdsT m ()
unsupported c = fail $ "extractIds: unsupported " ++ c

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
  extractIds (L _span (TypeSig names tp)) = do
    forM_ names $ \name -> record (getLoc name) NonBinding (unLoc name)
    extractIds tp
  extractIds (L _span (GenericSig _ _)) = unsupported "GenericSig"
  extractIds (L _span (IdSig _))        = unsupported "IdSig"
  extractIds (L _span (FixSig _))       = unsupported "FixSig"
  extractIds (L _span (InlineSig _ _))  = unsupported "InlineSig"
  extractIds (L _span (SpecSig _ _ _))  = unsupported "SpecSig"
  extractIds (L _span (SpecInstSig _))  = unsupported "SpecInstSig"

instance ConstructIdInfo id => ExtractIds (LHsType id) where
  extractIds (L _span (HsFunTy arg res)) =
    extractIds [arg, res]
  extractIds (L span (HsTyVar name)) =
    record span NonBinding name
  extractIds (L _span (HsForAllTy _explicitFlag tyVars _ctxt body)) = do
    extractIds tyVars
    extractIds body
  extractIds (L _span (HsAppTy fun arg)) =
    extractIds [fun, arg]
  extractIds (L _span (HsTupleTy _tupleSort typs)) =
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
  extractIds (L _span (HsTyLit _))             = unsupported "HsTyLit"
  extractIds (L _span (HsWrapTy _ _))          = unsupported "HsWrapTy"

instance ConstructIdInfo id => ExtractIds (LHsTyVarBndrs id) where
  extractIds (HsQTvs _kvs tvs) = do
    -- We don't have location info for the kind variables
    extractIds tvs

instance ConstructIdInfo id => ExtractIds (LHsTyVarBndr id) where
  extractIds (L span (UserTyVar name)) =
    record span Binding name
  extractIds (L span (KindedTyVar name _kind)) =
    record span Binding name

instance ConstructIdInfo id => ExtractIds (LHsBinds id) where
  extractIds = extractIds . bagToList

instance ConstructIdInfo id => ExtractIds (LHsBind id) where
  extractIds (L _span bind@(FunBind {})) = do
    record (getLoc (fun_id bind)) Binding (unLoc (fun_id bind))
    extractIds (fun_matches bind)
  extractIds (L _span _bind@(PatBind {})) =
    unsupported "PatBind"
  extractIds (L _span _bind@(VarBind {})) =
    unsupported "VarBind"
  extractIds (L _span bind@(AbsBinds {})) =
    extractIds (abs_binds bind)

instance ConstructIdInfo id => ExtractIds (MatchGroup id) where
  extractIds (MatchGroup matches _postTcType) = do
    extractIds matches
    -- We ignore the postTcType, as it doesn't have location information

instance ConstructIdInfo id => ExtractIds (LMatch id) where
  extractIds (L _span (Match pats _type rhss)) = do
    extractIds pats
    extractIds rhss

instance ConstructIdInfo id => ExtractIds (GRHSs id) where
  extractIds (GRHSs rhss binds) = do
    extractIds rhss
    extractIds binds

instance ConstructIdInfo id => ExtractIds (LGRHS id) where
  extractIds (L _span (GRHS _guards rhs)) = extractIds rhs

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
  extractIds (L _ (HsPar expr)) =
    extractIds expr
  extractIds (L _ (ExprWithTySig expr _type)) = do
    extractIds expr
    debugPP "ExprWithTySig" _type
  extractIds (L _ (ExprWithTySigOut expr _type)) = do
    extractIds expr
    debugPP "ExprWithTySig" _type
  extractIds (L _ (HsOverLit _ )) =
    return ()
  extractIds (L _ (OpApp left op _fix right)) = do
    extractIds [left, op, right]
  extractIds (L span (HsVar id)) =
    record span NonBinding id
  extractIds (L span (HsWrap _wrapper expr)) =
    extractIds (L span expr)
  extractIds (L _ (HsLet binds expr)) = do
    extractIds binds
    extractIds expr
  extractIds (L _ (HsApp fun arg)) =
    extractIds [fun, arg]
  extractIds (L _ (HsLit _)) =
    return ()
  extractIds (L _ (HsLam matches)) =
    extractIds matches
  extractIds (L _ (HsDo _ctxt stmts _postTcType)) =
    -- ctxt indicates what kind of statement it is; AFAICT there is no
    -- useful information in it for us
    -- postTcType is not located
    extractIds stmts
  extractIds (L _ (ExplicitList _postTcType exprs)) =
    extractIds exprs
  extractIds (L _ (RecordCon con _postTcType _recordBinds)) =
    record (getLoc con) NonBinding (unLoc con)
    -- TODO: deal with _recordBinds
  extractIds (L _ (HsCase expr matches)) = do
    extractIds expr
    extractIds matches

  extractIds (L _ (HsIPVar _ ))          = unsupported "HsIPVar"
  extractIds (L _ (HsLamCase _ _ ))      = unsupported "HsLamCase"
  extractIds (L _ (NegApp _ _))          = unsupported "NegApp"
  extractIds (L _ (SectionL _ _))        = unsupported "SectionL"
  extractIds (L _ (SectionR _ _))        = unsupported "SectionR"
  extractIds (L _ (ExplicitTuple _ _))   = unsupported "ExplicitTuple"
  extractIds (L _ (HsIf _ _ _ _))        = unsupported "HsIf"
  extractIds (L _ (HsMultiIf _ _))       = unsupported "HsMultiIf"
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

-- The meaning of the constructors of LStmt isn't so obvious; see various
-- notes in ghc/compiler/hsSyn/HsExpr.lhs
instance ConstructIdInfo id => ExtractIds (LStmt id) where
  extractIds (L _span (ExprStmt expr _seq _guard _postTcType)) =
    -- Neither _seq nor _guard are located
    extractIds expr
  extractIds (L _span (BindStmt pat expr _bind _fail)) = do
    -- Neither _bind or _fail are located
    extractIds pat
    extractIds expr
  extractIds (L _span (LetStmt binds)) =
    extractIds binds
  extractIds (L _span (LastStmt expr _return)) =
    extractIds expr




  extractIds (L _span (ParStmt _ _ _))    = unsupported "ParStmt"
  extractIds (L _span (TransStmt {}))     = unsupported "TransStmt"
  extractIds (L _span (RecStmt {}))       = unsupported "RecStmt"

instance ConstructIdInfo id => ExtractIds (LPat id) where
  extractIds (L _span (WildPat _postTcType)) =
    return ()
  extractIds (L span (VarPat id)) =
    record span Binding id
  extractIds (L _span (LazyPat pat)) =
    extractIds pat
  extractIds (L _span (AsPat id pat)) = do
    record (getLoc id) Binding (unLoc id)
    extractIds pat
  extractIds (L _span (ParPat pat)) =
    extractIds pat
  extractIds (L _span (BangPat pat)) =
    extractIds pat
  extractIds (L _span (ListPat pats _postTcType)) =
    extractIds pats
  extractIds (L _span (TuplePat pats _boxity _postTcType)) =
    extractIds pats
  extractIds (L _span (PArrPat pats _postTcType)) =
    extractIds pats
  extractIds (L _span p@(ConPatIn _ _)) = do
    debugPP "ConPatIn" p
  extractIds (L _span p@(ConPatOut {})) = do
    debugPP "ConPatOut" p

  -- View patterns
  extractIds (L _span (ViewPat _ _ _))     = unsupported "ViewPat"
  extractIds (L _span (QuasiQuotePat _))   = unsupported "QuasiQuotePat"
  extractIds (L _span (LitPat _))          = unsupported "LitPat"
  extractIds (L _span (NPat _ _ _))        = unsupported "NPat"
  extractIds (L _span (NPlusKPat _ _ _ _)) = unsupported "NPlusKPat"
  extractIds (L _span (SigPatIn _ _))      = unsupported "SigPatIn"
  extractIds (L _span (SigPatOut _ _))     = unsupported "SigPatOut"
  extractIds (L _span (CoPat _ _ _))       = unsupported "CoPat"
