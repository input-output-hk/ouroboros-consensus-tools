{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric  #-}

module Cardano.Beacon.CLI (
    ApplyMode (..)
  , Backend (..)
  , BeaconCommand (..)
  , BeaconOptions (..)
  , backendCLIOpts
  , getOpts
  ) where

import           Cardano.Beacon.Types
import           Data.Aeson
import           Data.Text as Text (pack)
import           GHC.Generics (Generic)
import           Options.Applicative


data BeaconCommand =
    -- commands that can be invoked from the CLI;
    -- commands can be chained
      BeaconListChains
    | BeaconBuild       !Version
    | BeaconDoRun       !ChainName !Version !Int !ApplyMode !(Maybe Backend)
    | BeaconStoreRun    !FilePath
    | BeaconSummary     !String
    | BeaconCompare     !String !(Maybe String)
    | BeaconVariance    !String

    -- commands that can't be used directly from the CLI
    | BeaconLoadChains
    | BeaconLoadCommit  !String
    deriving Show

data BeaconOptions = BeaconOptions {
      optEchoing   :: !EchoCommand
    , optBeaconDir :: !FilePath
    , optMachineId :: !String
    , optLockFile  :: !FilePath
    }
    deriving Show

data ApplyMode = Apply | Reapply deriving (Eq, Show, Generic, FromJSON, ToJSON)

data Backend = V1LMDB | V2InMem | V2LSM deriving (Eq, Show, Generic, FromJSON, ToJSON)

-- CLI options as understood by db-analyser
backendCLIOpts :: Backend -> String
backendCLIOpts = \case
  V1LMDB  -> "--lmdb"
  V2InMem -> "--in-mem"
  V2LSM   -> "--lsm"



--------------------------------------------------------------------------------
-- Command line parsing
--------------------------------------------------------------------------------

getOpts :: IO (BeaconOptions, [BeaconCommand])
getOpts = execParser $ info (parseCLI <**> helper) fullDesc

parseCLI :: Parser (BeaconOptions, [BeaconCommand])
parseCLI = (,) <$> parseOptions <*> some parseCommand

parseOptions :: Parser BeaconOptions
parseOptions =
  BeaconOptions
    <$> flag DoNotEchoCommand EchoCommand
        (mconcat
          [ short 'e'
          , long "echo"
          , help "Echo shell commands"
          ])
    <*> strOption
        (mconcat
          [ short 'd'
          , long "data-dir"
          , value "./beacon-data"
          , showDefault
          , metavar "DIR"
          , action "directory"
          , help "Specify beacon data directory"
          ])
    <*> strOption
        (mconcat
          [ long "id"
          , value ""
          , metavar "ID"
          , help "Set host identifier (default: hostname)"
          ])
    <*> strOption
        (mconcat
          [ long "lock"
          , value ""
          , metavar "FILE"
          , help "Use a lock file"
          ])

parseCommand :: Parser BeaconCommand
parseCommand =  subparser $ mconcat
  [ op "build" "Build and link target binary only"
      (BeaconBuild <$> parseVersion)
  , op "summary" "Show performance data of a stored run"
      (BeaconSummary <$> parseSlug)
  , op "compare" "Compare two stored runs"
      (BeaconCompare <$> parseSlug <*> (Just <$> parseSlug))
  , op "list-chains" "List registered chain fragments that beacon can be run on"
      (pure BeaconListChains)
  , op "run" "Perform a beacon run"
      (BeaconDoRun <$> (ChainName . Text.pack <$> parseChainName) <*> parseVersion <*> parseCount <*> parseApplyMode <*> parseBackend)
  , op "store" "Store a run, moving the given file"
      (BeaconStoreRun <$> parseFileName)
  , op "variance" "Perform variace analysis on all runs for certain slug"
      (BeaconVariance <$> parseSlug)
  , op "test-github" "Test the GitHub query on a given git ref"
      (BeaconLoadCommit <$> parseRevision)
  ]
  where
    op :: String -> String -> Parser a -> Mod CommandFields a
    op c descr p =
     command c $ info (p <**> helper) $
       mconcat [ progDesc descr ]

    parseRevision :: Parser String
    parseRevision = strOption
      (mconcat
        [ long "rev"
        , metavar "REF"
        , help "Commit hash (full or shortened) or tag or branch name"
        ])

    parseGHCVersion :: Parser String
    parseGHCVersion = strOption
      (mconcat
        [ long "ghc"
        , metavar "VER"
        , value "haskell96"
        , showDefault
        , help "Compiler version; cf. ouroboros-consensus-cardano/README.md#Assertions"
        ])

    parseChainName :: Parser String
    parseChainName = strOption
      (mconcat
        [ short 'n'
        , long "name"
        , metavar "NAME"
        , help "Chain fragment name to run on"
        ])

    parseCount :: Parser Int
    parseCount = option auto
      (mconcat
        [ short 'c'
        , value 1
        , showDefault
        , help "Number of times to perform the run"
        ])

    parseVersion :: Parser Version
    parseVersion =  Version <$> parseRevision <*> parseGHCVersion

    parseFileName :: Parser FilePath
    parseFileName = strArgument
      (mconcat
        [ metavar "FILE"
        , action "file"
        , help "JSON run file to be stored"
        ])

    parseSlug :: Parser String
    parseSlug = strArgument
      (mconcat
        [ metavar "SLUG"
        , help "slug specifying stored run(s)"
        ])

    parseApplyMode :: Parser ApplyMode
    parseApplyMode = flag Apply Reapply $
         long "reapply"
      <> help "Measure header/block *re*application instead of full application"

    parseBackend :: Parser (Maybe Backend)
    parseBackend = optional $
      asum
        [ flag' V1LMDB $
            mconcat
              [ long "lmdb"
              , help "use v1 LMDB backing store"
              ]
        , flag' V2InMem $
            mconcat
              [ long "in-mem"
              , help "use v2 in-memory backend (the default)"
              ]
        , flag' V2LSM $
            mconcat
              [ long "lsm"
              , help "use v2 LSM backend"
              ]
        ]
