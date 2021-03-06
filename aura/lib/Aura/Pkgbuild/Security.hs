{-# LANGUAGE OverloadedStrings, TupleSections, TypeApplications, DeriveGeneric #-}

-- |
-- Module    : Aura.Pkgbuild.Security
-- Copyright : (c) Colin Woodbury, 2012 - 2018
-- License   : GPL3
-- Maintainer: Colin Woodbury <colin@fosskers.ca>
--
-- Analyse PKGBUILDs for potentially malicious bash code.

module Aura.Pkgbuild.Security
  ( BannedTerm(..), BanCategory(..)
  , parsedPB, bannedTerms
  , reportExploit
  ) where

import           Aura.Languages
import           Aura.Types (Pkgbuild(..), Language)
import           Aura.Utils (strictText)
import           BasePrelude hiding (Last, Word)
import           Control.Error.Util (hush)
import           Data.Generics.Product
import qualified Data.Map.Strict as M
import qualified Data.Text as T
import           Data.Text.Prettyprint.Doc (Doc)
import           Data.Text.Prettyprint.Doc.Render.Terminal (AnsiStyle)
import           Language.Bash.Parse (parse)
import           Language.Bash.Syntax
import           Language.Bash.Word (Word, unquote, Span(..))
import           Lens.Micro

---

-- | A bash term which should never appear in a PKGBUILD. If one does, it's
-- either a sign of maintainer negligence or malicious behaviour.
data BannedTerm = BannedTerm T.Text BanCategory deriving (Eq, Ord, Show, Generic)

-- | The reason why the bash term is black-listed.
data BanCategory = Downloading
                 | ScriptRunning
                 | Permissions
                 | InlinedBash
                 | StrangeBashism
                 | CleverRedirect
                 deriving (Eq, Ord, Show)

blacklist :: M.Map T.Text BannedTerm
blacklist = M.fromList $ downloading <> running <> permissions
  where downloading = map (\t -> (t, BannedTerm t Downloading)) ["curl", "wget", "rsync", "scp"]
        running     = map (\t -> (t, BannedTerm t ScriptRunning)) ["sh", "bash", "eval", "zsh", "fish"]
        permissions = map (\t -> (t, BannedTerm t Permissions)) ["sudo", "ssh"]

-- | Attempt to parse a PKGBUILD. Should succeed for all reasonable PKGBUILDs.
parsedPB :: Pkgbuild -> Maybe List
parsedPB (Pkgbuild pb) = hush . parse "PKGBUILD" . T.unpack $ strictText pb  -- TODO wasteful conversion!

-- | Discover any banned terms lurking in a parsed PKGBUILD, paired with
-- the surrounding context lines.
bannedTerms :: List -> [(ShellCommand, BannedTerm)]
bannedTerms = simpleCommands >=> bannedCommand

banned :: Word -> Maybe BannedTerm
banned w = M.lookup (T.pack $ unquote w) blacklist

-- | Extract all `SimpleCommand`s from a parsed bash AST.
simpleCommands :: List -> [ShellCommand]
simpleCommands l = l ^.. types @ShellCommand . to p . each
  where p sc@(SimpleCommand _ _) = [sc]
        p sc = sc ^.. types @List . to simpleCommands . each

bannedCommand :: ShellCommand -> [(ShellCommand, BannedTerm)]
bannedCommand s@(SimpleCommand [] (g:c:_))
  | g == [Char 'g', Char 'i', Char 't'] &&
    c == [Char 'c', Char 'l', Char 'o', Char 'n', Char 'e'] = [(s, BannedTerm "git" Downloading)]
bannedCommand s@(SimpleCommand [] (c:_)) = maybeToList $ (s,) <$> banned c
bannedCommand s@(SimpleCommand as _) = as ^.. each . typed @RValue . to r . each
  where
    r rv@(RValue w) = maybeToList ((s,) <$> (banned w & _Just . typed @BanCategory .~ CleverRedirect)) <> q rv
    r rv = q rv

    q :: RValue -> [(ShellCommand, BannedTerm)]
    q rv = rv ^.. types @Word . each . to p . each . to (s,)

    p (CommandSubst str)   = maybeToList (hush $ parse "CommandSubst" str) >>= simpleCommands >>= map snd . bannedCommand
    p (ArithSubst str)     = [BannedTerm (T.pack str) StrangeBashism]
    p (ProcessSubst _ str) = [BannedTerm (T.pack str) StrangeBashism]
    p sp = sp ^.. types @Word . each . to p . each
bannedCommand _ = []

------------
-- REPORTING
------------

-- | Dispatch different error messages depending on the category of a `BannedTerm`.
reportExploit :: BannedTerm -> (Language -> Doc AnsiStyle)
reportExploit (BannedTerm t bc) = case bc of
  Downloading    -> security_2 t
  ScriptRunning  -> security_3 t
  Permissions    -> security_4 t
  InlinedBash    -> security_8 t
  StrangeBashism -> security_9 t
  CleverRedirect -> security_10 t
