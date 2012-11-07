-- Copyright   : (c) JP Moresmau 2011,
--                   Well-Typed 2012

-- (JP Moresmau's buildwrapper package used as template for GHC API use)

{-# LANGUAGE CPP #-}

module Main where

import GHC hiding (flags, ModuleName)
import qualified Config as GHC
#if __GLASGOW_HASKELL__ >= 706
import ErrUtils   ( MsgDoc )
#else
import ErrUtils   ( Message )
#endif
import Outputable ( PprStyle, showSDocForUser, qualName, qualModule )
import FastString ( unpackFS )
import StringBuffer ( stringToStringBuffer )

import Text.JSON as JSON

import System.Environment
import System.Process
#if __GLASGOW_HASKELL__ >= 706
import Data.Time
#else
import System.Time
#endif
import Data.Map (Map)
import qualified Data.Map as Map
import qualified Data.List as List
import Data.IORef
import Data.Monoid ((<>))
import Data.Maybe (fromMaybe)
import Control.Monad
import Control.Applicative
import Control.Exception
import Control.Concurrent
import System.Directory
import System.Random (randomIO)
import System.FilePath (combine, takeExtension)
import System.IO.Unsafe (unsafePerformIO)  -- horrors

import Data.Monoid (Monoid(..))
import Data.ByteString.Lazy.Char8 (ByteString)
import qualified Data.ByteString.Lazy.Char8 as BS

-- Mock-up filesystem to avoid trashing our computers when testing.
-- Files not present in the map should be read from the real filesystem.
type Filesystem = Map FilePath ByteString

filesystem :: IORef Filesystem
{-# NOINLINE filesystem #-}
filesystem = unsafePerformIO $ newIORef $ Map.empty

type GhcState = [Located String]

-- In this implementation, it's fully applicative, and so invalid sessions
-- can be queried at will. Note that there may be some working files
-- produced by GHC while obtaining these values. They are not captured here,
-- so queries are not allowed to read them.
type Computed = [SourceError]

data IdeSession = IdeSession SessionConfig GhcState
                             (MVar StateToken) StateToken (Maybe Computed)

data StateToken = StateToken Int
  deriving (Eq, Show)

initialToken :: StateToken
initialToken = StateToken 1

incrementToken :: StateToken -> StateToken
incrementToken (StateToken n) = StateToken $ n + 1

data SessionConfig = SessionConfig {

       -- | The directory to use for managing source files.
       configSourcesDir :: FilePath,

       -- | The directory to use for session state, such as @.hi@ files.
       configWorkingDir :: FilePath,

       -- | The directory to use for data files that may be accessed by the
       -- running program. The running program will have this as its CWD.
       configDataDir :: FilePath,

       -- | The directory to use for purely temporary files.
       configTempDir :: FilePath
     }

initSession :: SessionConfig -> IO IdeSession
initSession sessionConfig = do
  let opts = []  -- GHC static flags; set them in sessionConfig?
  (leftoverOpts, _) <- parseStaticFlags (map noLoc opts)
  let computed = Nothing  -- can't query before the first Progress
  currentToken <- newMVar initialToken
  return $ IdeSession sessionConfig leftoverOpts
                      currentToken initialToken computed

shutdownSession :: IdeSession -> IO ()
shutdownSession (IdeSession _ _ currentToken token _) = do
  -- Invalidate the session.
  let incrCheckToken curToken = do
        checkToken token curToken
        let newT = incrementToken token
        return newT
  modifyMVar_ currentToken incrCheckToken
  -- no other resources to free

checkToken :: StateToken -> StateToken -> IO ()
checkToken token curToken =
  when (token /= curToken) $
    error $ "Invalid session token " ++ show token ++ " /= " ++ show curToken

data IdeSessionUpdate = IdeSessionUpdate (IO ())

instance Monoid IdeSessionUpdate where
  mempty = IdeSessionUpdate $ return ()
  mappend (IdeSessionUpdate a) (IdeSessionUpdate b) =
    IdeSessionUpdate $ a >> b

updateSession :: IdeSession -> IdeSessionUpdate -> IO (Progress IdeSession)
updateSession (IdeSession conf@SessionConfig{configSourcesDir} ghcSt currentToken token _)
              (IdeSessionUpdate update) = do
  -- First, invalidatin the current session ASAP, because the previous
  -- computed info will shortly no longer be in sync with the files.
  let incrCheckToken curToken = do
        checkToken token curToken
        let newT = incrementToken token
        return (newT, newT)
  newToken <- modifyMVar currentToken incrCheckToken

  -- Then, updating files ASAP.
  update

  -- Last, spawning a future.
  progressSpawn $ do
    fs <- readIORef filesystem
    let checkSingle file = do
          let mcontent = fmap BS.unpack $ Map.lookup file fs
          errs <- checkModule file mcontent ghcSt
          return $ formatErrorMessagesJSON errs
    cnts <- getDirectoryContents configSourcesDir
    let files = filter ((`elem` [".hs"]) . takeExtension) cnts
    allErrs <- mapM checkSingle files
    let computed = Just allErrs  -- can query now
    return $ IdeSession conf ghcSt currentToken newToken computed

data Progress a = Progress (MVar a)

progressSpawn :: IO a -> IO (Progress a)
progressSpawn action = do
  mv <- newEmptyMVar
  let actionMv = do
        a <- action
        putMVar mv a
  void $ forkIO actionMv
  return $ Progress mv

progressWaitCompletion :: Progress a -> IO a
progressWaitCompletion (Progress mv) = takeMVar mv

-- TODO:
-- 12:31 < dcoutts> mikolaj: steal the writeFileAtomic code from Cabal
-- 12:31 < dcoutts> from D.S.Utils
-- 12:32 < dcoutts> though check it's the version that uses ByteString
-- 12:32 < dcoutts> rather than String
updateModule :: ModuleChange -> IdeSessionUpdate
updateModule mc = IdeSessionUpdate $ do
  fs <- readIORef filesystem
  let newFs = case mc of
        ModulePut n bs -> Map.insert n bs fs
        ModuleDelete n -> Map.delete n fs
  writeIORef filesystem newFs

data ModuleChange = ModulePut    ModuleName ByteString
                  | ModuleDelete ModuleName

type ModuleName = String  -- TODO: use GHC.Module.ModuleName ?

updateDataFile :: DataFileChange -> IdeSessionUpdate
updateDataFile mc = IdeSessionUpdate $ do
  fs <- readIORef filesystem
  let newFs = case mc of
        DataFilePut n bs -> Map.insert n bs fs
        DataFileDelete n -> Map.delete n fs
  writeIORef filesystem newFs

data DataFileChange = DataFilePut    FilePath ByteString
                    | DataFileDelete FilePath

type Query a = IdeSession -> IO a

getSourceModule :: ModuleName -> Query ByteString
getSourceModule n (IdeSession (SessionConfig{configSourcesDir}) _ _ _ _) = do
  fs <- readIORef filesystem
  case Map.lookup n fs of
    Just bs -> return bs
    Nothing -> BS.readFile (combine configSourcesDir n)

getDataFile :: FilePath -> Query ByteString
getDataFile = getSourceModule

getSourceErrors :: Query [SourceError]
getSourceErrors (IdeSession _ _ _ _ msgs) =
  let err = error $ "This session state does not admit queries."
  in return $ fromMaybe err msgs

type SourceError = String  -- TODO


-- Old code, still used in this mock-up.

checkModule :: FilePath          -- ^ target file
            -> Maybe String      -- ^ optional content of the file
            -> [Located String]  -- ^ leftover ghc static options
            -> IO [ErrorMessage] -- ^ any errors and warnings
checkModule filename mfilecontent leftoverOpts = handleOtherErrors $ do

    libdir <- getGhcLibdir

    errsRef <- newIORef []

    mcontent <- case mfilecontent of
                  Nothing          -> return Nothing
                  Just filecontent -> do
#if __GLASGOW_HASKELL__ >= 704
                    let strbuf = stringToStringBuffer filecontent
#else
                    strbuf <- stringToStringBuffer filecontent
#endif
#if __GLASGOW_HASKELL__ >= 706
                    strtime <- getCurrentTime
#else
                    strtime <- getClockTime
#endif
                    return (Just (strbuf, strtime))

    runGhc (Just libdir) $
#if __GLASGOW_HASKELL__ >= 706
      handleSourceError printException $ do
#else
      handleSourceError printExceptionAndWarnings $ do
#endif

      flags0 <- getSessionDynFlags
      (flags, _, _) <- parseDynamicFlags flags0 leftoverOpts

      defaultCleanupHandler flags $ do
        setSessionDynFlags flags {
                             hscTarget  = HscNothing,
                             ghcLink    = NoLink,
                             ghcMode    = CompManager,
                             log_action = collectSrcError errsRef
                           }
        addTarget Target {
                    targetId           = TargetFile filename Nothing,
                    targetAllowObjCode = True,
                    targetContents     = mcontent
                  }
        load LoadAllTargets
        return ()

    reverse <$> readIORef errsRef
  where
    handleOtherErrors =
      handle $ \e -> return [OtherError (show (e :: SomeException))]

getGhcLibdir :: IO FilePath
getGhcLibdir = do
  let ghcbinary = "ghc-" ++ GHC.cProjectVersion
  out <- readProcess ghcbinary ["--print-libdir"] ""
  case lines out of
    [libdir] -> return libdir
    _        -> fail "cannot parse output of ghc --print-libdir"

data ErrorMessage = SrcError   ErrorKind FilePath (Int, Int) (Int, Int) String
                  | OtherError String
  deriving Show
data ErrorKind    = Error | Warning
  deriving Show

#if __GLASGOW_HASKELL__ >= 706
collectSrcError :: IORef [ErrorMessage]
                -> DynFlags
                -> Severity -> SrcSpan -> PprStyle -> MsgDoc -> IO ()
collectSrcError errsRef flags severity srcspan style msg
  | Just errKind <- case severity of
                      SevWarning -> Just Main.Warning
                      SevError   -> Just Main.Error
                      SevFatal   -> Just Main.Error
                      _          -> Nothing
  , Just (file, st, end) <- extractErrSpan srcspan
  = let msgstr = showSDocForUser flags (qualName style,qualModule style) msg
     in modifyIORef errsRef (SrcError errKind file st end msgstr:)

collectSrcError errsRef flags SevError _srcspan style msg
  = let msgstr = showSDocForUser flags (qualName style,qualModule style) msg
     in modifyIORef errsRef (OtherError msgstr:)

collectSrcError _ _ _ _ _ _ = return ()
#else
collectSrcError :: IORef [ErrorMessage]
                -> Severity -> SrcSpan -> PprStyle -> Message -> IO ()
collectSrcError errsRef severity srcspan style msg
  | Just errKind <- case severity of
                      SevWarning -> Just Main.Warning
                      SevError   -> Just Main.Error
                      SevFatal   -> Just Main.Error
                      _          -> Nothing
  , Just (file, st, end) <- extractErrSpan srcspan
  = let msgstr = showSDocForUser (qualName style,qualModule style) msg
     in modifyIORef errsRef (SrcError errKind file st end msgstr:)

collectSrcError errsRef SevError _srcspan style msg
  = let msgstr = showSDocForUser (qualName style,qualModule style) msg
     in modifyIORef errsRef (OtherError msgstr:)

collectSrcError _ _ _ _ _ = return ()
#endif

extractErrSpan :: SrcSpan -> Maybe (FilePath, (Int, Int), (Int, Int))
#if __GLASGOW_HASKELL__ >= 704
extractErrSpan (RealSrcSpan srcspan) =
#else
extractErrSpan srcspan | isGoodSrcSpan srcspan =
#endif
  Just (unpackFS (srcSpanFile srcspan)
       ,(srcSpanStartLine srcspan, srcSpanStartCol srcspan)
       ,(srcSpanEndLine   srcspan, srcSpanEndCol   srcspan))
extractErrSpan _ = Nothing

formatErrorMessagesJSON :: [ErrorMessage] -> String
formatErrorMessagesJSON = JSON.encode . map errorMessageToJSON

errorMessageToJSON :: ErrorMessage -> JSValue
errorMessageToJSON (SrcError errKind file (stline, stcol)
                                          (endline, endcol) msgstr) =
  JSObject $
    toJSObject
      [ ("kind",      showJSON (toJSString (show errKind)))
      , ("file",      showJSON (toJSString file))
      , ("startline", showJSON stline)
      , ("startcol",  showJSON stcol)
      , ("endline",   showJSON endline)
      , ("endcol",    showJSON endcol)
      , ("message",   showJSON (toJSString msgstr))
      ]
errorMessageToJSON (OtherError msgstr) =
  JSObject $
    toJSObject
      [ ("kind",      showJSON (toJSString "message"))
      , ("message",   showJSON (toJSString msgstr))
      ]

-- Test the stuff.

main :: IO ()
main = do
  args <- getArgs
  let configSourcesDir = case args of
        [dir] -> dir
        [] -> "."
        _ -> fail "usage: ghc-vs-helper [source-dir]"
  let sessionConfig = SessionConfig{..}
  -- Two sample scenarios:
  b <- randomIO
  if b
    then do
      s0 <- initSession sessionConfig
      let update1 =
            (updateModule $ ModulePut "ghc-vs-helper.hs" (BS.pack "1"))
            <> (updateModule $ ModulePut "ghc-vs-helper.hs" (BS.pack "x = a1"))
          update2 =
            (updateModule $ ModulePut "ghc-vs-helper.hs" (BS.pack "2"))
            <> (updateModule $ ModulePut "ghc-vs-helper.hs" (BS.pack "x = a2"))
      progress1 <- updateSession s0 update1
      s2 <- progressWaitCompletion progress1
      msgs2 <- getSourceErrors s2
      putStrLn $ "Errors 2: " ++ List.intercalate "\n\n" msgs2
      progress3 <- updateSession s2 update2  -- s0 should fail
      s4 <- progressWaitCompletion progress3
      msgs4 <- getSourceErrors s4
      putStrLn $ "Errors 4: " ++ List.intercalate "\n\n" msgs4
      msgs2' <- getSourceErrors s2
      putStrLn $ "Errors 2 again: " ++ List.intercalate "\n\n" msgs2'
      shutdownSession s4
    else do
      s0 <- initSession sessionConfig
      progress <- updateSession s0 mempty
      s1 <- progressWaitCompletion progress
      msgs1 <- getSourceErrors s1
      putStrLn $ "Errors 1: " ++ List.intercalate "\n\n" msgs1
      shutdownSession s1  -- s0 should fail
