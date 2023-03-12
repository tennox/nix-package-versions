{- This module takes care of populating the database
-}

module App.Update
  ( savePackageVersionsForPeriod
  ) where

import Control.Concurrent (getNumCapabilities)
import Control.Concurrent.Async (forConcurrently)
import Control.Concurrent.MVar (MVar, modifyMVar, readMVar, newMVar)
import Control.Exception (mask, onException)
import Control.Monad (void, when)
import Control.Monad.STM (atomically)
import Control.Concurrent.STM.TVar
  (newTVarIO, readTVar, writeTVar, TVar)
import Control.Monad.STM.Class (retry)
import Data.Foldable (traverse_)
import qualified Data.Map as Map
import Data.Map (Map)
import Prettyprinter (pretty)
import System.IO (hPutStrLn, stderr)

import App.Storage (Database, CommitState(..))
import qualified App.Storage as Storage
import Control.Concurrent.Extra (stream)
import Data.Git (Commit(..))
import Data.Time.Period (Period(..), PeriodLength)
import GitHub (AuthenticatingUser(..))
import qualified GitHub
import Nix
  ( Channel(..)
  , nixpkgsRepo
  , channelBranch)
import qualified Nix
import System.Timed (timed)

data State = State
  { s_commits :: MVar (Map Commit (TVar CommitState))
  }

getOrCreateStateFor :: State -> Commit -> IO (TVar CommitState, Bool)
getOrCreateStateFor State{..} commit =
  modifyMVar s_commits $ \commits ->
  case Map.lookup commit commits of
    Just var -> return (commits, (var, False))
    Nothing -> do
      var <- newTVarIO Incomplete
      return (Map.insert commit var commits, (var, True))

setStateFor :: State -> Commit -> CommitState -> IO ()
setStateFor state commit cstate = do
  var <- getStateFor state commit
  atomically $ writeTVar var cstate

getStateFor :: State -> Commit -> IO (TVar CommitState)
getStateFor State{..} commit = do
  commits <- readMVar s_commits
  case Map.lookup commit commits of
    Nothing -> error "getStateFor"
    Just var -> return var

process :: Database -> State -> Commit -> IO (TVar CommitState)
process db state commit = do
  (var, created) <- getOrCreateStateFor state commit
  when created $
    (do
      epackages <- Nix.packagesAt commit
      finalState <- save epackages
      setStateFor state commit finalState)
    `onException` setStateFor state commit Broken
  return var
  where
    save = \case
      Right packages ->
        timed ("Saved successfully " <> show commit) $ do
          let before = Storage.writeCommitState db commit Incomplete
              succeed = Storage.writeCommitState db commit Success
              failure = Storage.writeCommitState db commit Broken
              act = traverse_ (Storage.writePackage db commit) packages
          mask $ \release -> do
            before
            release act `onException` failure
            succeed
          return Success
      Left err -> do
        hPutStrLn stderr $
          "Save failed for " <> show commit <> " : " <> show err
        Storage.writeCommitState db commit Broken
        return Broken

-- Download package information from Nix and save it to the database
-- handling at most `concurrency` parallel commits at once.
--
-- No commit is handled twice. The second time will just point to the
-- result of the first time it was attempted.
parallelWriter
  :: Database
  -> Int
  -- ^ max parallelism
  -> ((Commit -> IO Bool) -> IO a)
    -- ^ save data about a commit to the db
  -> IO a
parallelWriter db concurrency f = do
  var <- newMVar mempty
  let state = State var
      -- run at most `concurrency` of these in parallel.
      -- only blocks if the Commit hasn't been handled before.
      consume commit = void $ process db state commit
      produce enqueue = f $ \commit -> do
        () <- enqueue commit
        cvar <- getStateFor state commit
        atomically $ do
          cstate <- readTVar cvar
          if not (isFinal cstate)
            then retry
            else return $ cstate == Success
  stream concurrency produce consume

-- | Download lists of packages and their versions for commits
-- between 'to' and 'from' dates and save them to the database.
savePackageVersionsForPeriod
  :: Database
  -> PeriodLength
  -> AuthenticatingUser
  -> Period
  -> IO [Either String String]
savePackageVersionsForPeriod database len user targetPeriod = do
  let channels = [minBound..]
  coverages <- zip channels <$> traverse (Storage.coverage database) channels
  let completed :: Map Commit CommitState
      completed = foldr add mempty $ concatMap snd coverages
        where
        add (_, commit, state) acc = Map.insert commit state acc

      wanted :: [Period]
      wanted =
        [ Period from (from + realToFrac len)
        | from <- [start, start + realToFrac len .. end ]
        ]
        where Period start end = targetPeriod

      missing :: [(Channel, Period)]
      missing =
        [ (channel, period)
        | channel <- channels
        , Just covered <- [lookup channel coverages]
        , period <- wanted
        -- we consider an expanded period such that if there is coverage
        -- withnin this time, then the period can be considered covered.
        , not $ any (within $ expanded period) covered
        ]
        where
          expanded (Period s e) = Period (s - halfLen) (e + halfLen)
            where halfLen = realToFrac len / 2

          within (Period s e) (Period s' e',_,state) =
            s <= s' && e' <= e && state == Success

  capabilities <- getNumCapabilities
  -- leave some threads to avoid making the machine unresponsive.
  let concurrency = max 1 $ capabilities - 4
  parallelWriter database concurrency $ \save -> do
    let handled :: Commit -> Bool
        handled commit =
          maybe False isFinal $
          Map.lookup commit completed

        processPeriod :: Channel -> Period -> IO (Either String String)
        processPeriod channel period = do
          commits <- commitsWithin channel period
          let maxAttempts = 10
              pending = take maxAttempts $ filter (not . handled) commits
          success <- tryInSequence $ map save pending
          return $ if success
            then Right $ unwords ["Success:", show channel,show $ pretty period]
            else Left $ unwords ["Failure:", show channel, show $ pretty period]

    forConcurrently missing (uncurry processPeriod)
  where
  commitsWithin :: Channel -> Period -> IO [Commit]
  commitsWithin channel (Period _ end) = do
    r <- GitHub.commitsUntil user 30 nixpkgsRepo (channelBranch channel) end
    case r of
      Left err -> do
        hPutStrLn stderr $ "Failed to list facts from GitHub: " <> show err
        return []
      Right commits ->
        return commits

-- stops on first True
tryInSequence :: [IO Bool] -> IO Bool
tryInSequence [] = return False
tryInSequence (x:xs) = x >>= \case
  True -> return True
  False -> tryInSequence xs

isFinal :: CommitState -> Bool
isFinal = \case
  Success    -> True
  Broken     -> True
  Incomplete -> False

