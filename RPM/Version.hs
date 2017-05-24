-- Copyright (C) 2017 Red Hat, Inc.
--
-- This library is free software; you can redistribute it and/or
-- modify it under the terms of the GNU Lesser General Public
-- License as published by the Free Software Foundation; either
-- version 2.1 of the License, or (at your option) any later version.
--
-- This library is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
-- Lesser General Public License for more details.
--
-- You should have received a copy of the GNU Lesser General Public
-- License along with this library; if not, see <http://www.gnu.org/licenses/>.

{-# LANGUAGE MultiWayIf #-}

module RPM.Version(DepOrdering(..),
                   DepRequirement(..),
                   EVR(..),
                   parseEVR,
                   parseDepRequirement,
                   satisfies,
                   vercmp)
 where

import           Data.Char(digitToInt, isAsciiLower, isAsciiUpper, isDigit, isSpace)
import           Data.Maybe(fromMaybe)
import           Data.Monoid((<>))
import qualified Data.Ord as Ord
import           Data.Word(Word32)
import           Text.Parsec

import Prelude hiding(EQ, GT, LT)

-- optional epoch, version, release
data EVR = EVR {
    epoch :: Maybe Word32,
    version :: String,
    release :: String }
 deriving(Show)

-- for Ord and Eq, an epoch of Nothing is the same as an epoch of 0.
-- for Eq, version and release strings need to go through vercmp, since they can be equivalent
-- without being the same String.
instance Eq EVR where
    (==) evr1 evr2 = evr1 `compare` evr2 == Ord.EQ

instance Ord EVR where
    compare evr1 evr2 = fromMaybe 0 (epoch evr1) `compare` fromMaybe 0 (epoch evr2) <>
                        version evr1 `vercmp` version evr2 <>
                        release evr1 `vercmp` release evr2

-- Like Ordering, but with >= and <=
data DepOrdering = LT | LTE | EQ | GTE | GT
 deriving(Eq, Show)

data DepRequirement = DepRequirement String (Maybe (DepOrdering, EVR))
 deriving (Eq, Show)

vercmp :: String -> String -> Ordering
vercmp a b = let
    -- strip out all non-version characters
    -- keep in mind the strings may be empty after this
    a' = dropSeparators a
    b' = dropSeparators b
  in
    case (a', b') of
        -- Nothing left means the versions are equal
        ([], [])   -> Ord.EQ
        -- tilde ls less than everything, including an empty string
        ('~':aTail, '~':bTail) -> vercmp aTail bTail
        ('~':_, _) -> Ord.LT
        (_, '~':_) -> Ord.GT
        -- otherwise, if one of the strings is null, the other is greater
        ([], _)    -> Ord.LT
        (_, [])    -> Ord.GT
        -- Now we have two non-null strings, starting with a non-tilde version character
        _          -> let 
            -- rpm compares strings by digit and non-digit components, so grab the first
            -- component of one type
            fn = if isDigit (head a') then isDigit else isAsciiAlpha
            (prefixA, suffixA) = span fn a'
            (prefixB, suffixB) = span fn b'
         in
            -- if one prefix is a number and the other is a string, the one
            -- that is a number is the more recent version number
            if | isDigit (head a') && (not . isDigit) (head b') -> Ord.GT
               | (not . isDigit) (head a') && isDigit (head b') -> Ord.LT
               | isDigit (head a') -> (prefixA `compareAsInts` prefixB) `mappend` (suffixA `vercmp` suffixB)
               | otherwise -> (prefixA `compare` prefixB) `mappend` (suffixA `vercmp` suffixB)
  where
    compareAsInts :: String -> String -> Ordering
    -- the version numbers can overflow Int, so strip leading 0's and do a string compare,
    -- longest string wins
    compareAsInts x y =
        let x' = dropWhile (== '0') x
            y' = dropWhile (== '0') y
        in 
            if length x' > length y' then Ord.GT
            else x' `compare` y'

    -- isAlpha returns any unicode alpha, but we just want ASCII characters
    isAsciiAlpha :: Char -> Bool
    isAsciiAlpha x = isAsciiLower x || isAsciiUpper x

    -- RPM only cares about ascii digits, ascii alpha, and ~
    isVersionChar :: Char -> Bool
    isVersionChar x = isDigit x || isAsciiAlpha x || x == '~'

    dropSeparators :: String -> String
    dropSeparators = dropWhile (not . isVersionChar)

{-# ANN satisfies "HLint: ignore Redundant if" #-}
satisfies :: DepRequirement -> DepRequirement -> Bool
satisfies (DepRequirement name1 ver1) (DepRequirement name2 ver2) =
    -- names have to match
    if name1 /= name2 then False
    else satisfiesVersion ver1 ver2
 where
    -- If either half has no version expression, it's a match
    satisfiesVersion Nothing _ = True
    satisfiesVersion _ Nothing = True

    -- There is a special case for matching versions with no release component.
    -- If one side is equal to (or >=, or <=) a version with no release component, it will match any non-empty
    -- release on the other side, regardless of operator.
    -- For example: x >= 1.0 `satisfies` x < 1.0-47.
    -- If *both* sides have no release, the regular rules apply, so x >= 1.0 does not satisfy x < 1.0

    satisfiesVersion (Just (o1, v1)) (Just (o2, v2))
        | null (release v1) && (not . null) (release v2) && compareEV v1 v2 && isEq o1 = True
        | null (release v2) && (not . null) (release v1) && compareEV v1 v2 && isEq o2 = True
        | otherwise =
            case compare v1 v2 of
                -- e1 < e2, true if >[=] e1 || <[=] e2
                Ord.LT -> isGt o1 || isLt o2
                -- e1 > e2, true if <[=] e1 || >[=] e2
                Ord.GT -> isLt o1 || isGt o2
                -- e1 == e2, true if both sides are the same direction
                Ord.EQ -> (isLt o1 && isLt o2) || (isEq o1 && isEq o2) || (isGt o1 && isGt o2)

    isEq EQ  = True
    isEq GTE = True
    isEq LTE = True
    isEq _   = False

    isLt LT  = True
    isLt LTE = True
    isLt _   = False

    isGt GT  = True
    isGt GTE = True
    isGt _   = False

    compareEV v1 v2 = fromMaybe 0 (epoch v1) == fromMaybe 0 (epoch v2) && version v1 == version v2

-- parsers for version strings
-- the EVR Parsec is shared by the EVR and DepRequirement parsers
parseEVRParsec :: Parsec String () EVR
parseEVRParsec = do
    e <- optionMaybe $ try parseEpoch
    v <- many1 versionChar
    r <- try parseRelease <|> return ""
    eof

    return EVR{epoch=e, version=v, release=r}
 where
    parseEpoch :: Parsec String () Word32
    parseEpoch = do
        e <- many1 digit
        _ <- char ':'

        -- parse the digit string as an Integer until it ends or overflows Word32
        parseInteger 0 e
     where
        maxW32 = toInteger (maxBound :: Word32)

        parseInteger :: Integer -> String -> Parsec String () Word32
        parseInteger acc []     = return $ fromInteger acc
        parseInteger acc (x:xs) = let
            newAcc = (acc * (10 :: Integer)) + toInteger (digitToInt x)
         in
            if newAcc > maxW32 then parserFail ""
            else parseInteger newAcc xs

    parseRelease = do
        _ <- char '-'
        many1 versionChar

    versionChar = digit <|> upper <|> lower <|> oneOf "._+%{}~"

parseEVR :: String -> Either ParseError EVR
parseEVR = parse parseEVRParsec ""

parseDepRequirement :: String -> Either ParseError DepRequirement
parseDepRequirement input = parse parseDepRequirement' "" input
 where
    parseDepRequirement' = do
        reqname <- many $ satisfy (not . isSpace)
        spaces
        reqver <- optionMaybe $ try parseDepVersion

        -- If anything went wrong in parsing the version (invalid operator, malformed EVR), treat the entire
        -- string as a name. This way RPMs with bad version strings in Requires, which of course exist, will
        -- match against the full string.
        case reqver of
            Just _  -> return $ DepRequirement reqname reqver
            Nothing -> return $ DepRequirement input Nothing

    -- check lte and gte first, since they overlap lt and gt
    parseOperator :: Parsec String () DepOrdering
    parseOperator = lte <|> gte <|> eq <|> lt <|> gt

    eq  = try (string "=")  >> return EQ
    lt  = try (string "<")  >> return LT
    gt  = try (string ">")  >> return GT
    lte = try (string "<=") >> return LTE
    gte = try (string ">=") >> return GTE

    parseDepVersion :: Parsec String () (DepOrdering, EVR)
    parseDepVersion = do
        oper <- parseOperator
        spaces
        evr <- parseEVRParsec
        eof

        return (oper, evr)
