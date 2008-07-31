{-  ID:         $Id$
    Author:     Tobias C. Rittweiler, TU Muenchen
-}

module Importer.Adapt.Mapping 
    (AdaptionTable(..), adaptionTable, 
     makeGlobalEnv_FromAdaptionTable, filterAdaptionTable) 
where

import List (intersperse, group, groupBy, sort, sortBy, nub)

import Data.Maybe
import qualified Data.Map as Map

import Language.Haskell.Exts

import Importer.Utilities.Misc (wordsBy, hasDuplicates, prettyShow', trace, assert)
import Importer.Utilities.Hsk (string2HsName)

import qualified Importer.LexEnv as Env

import qualified Importer.IsaSyntax as Isa

import Importer.Adapt.Common

import Importer.Adapt.Raw (raw_adaption_table)

data AdaptionTable = AdaptionTable [(Env.Identifier, Env.Identifier)]
  deriving Show

adaptionTable :: AdaptionTable
adaptionTable 
    = AdaptionTable 
        $ map (\(hEntry, iEntry) -> (parseEntry hEntry, parseEntry iEntry))
              (check_raw_adaption_table raw_adaption_table)

check_raw_adaption_table :: [(AdaptionEntry, AdaptionEntry)] -> [(AdaptionEntry, AdaptionEntry)]
check_raw_adaption_table tbl
    = let (hsk_entries, _) = unzip tbl
          names            = [ n | Haskell n _ <- hsk_entries ]
          methods          = concatMap (\(Haskell _ (Class (RawClassInfo { methods = m }))) -> fst (unzip m))
                              $ filter isClassEntry hsk_entries
          functions        = [ n | Haskell n Function <- filter isFunctionEntry hsk_entries ]
      in 
        if (hasDuplicates names)
        then error ("Duplicates in Raw Adaption Table found: "
                    ++ show (filter (flip (>) 1 . length) (group (sort names))))
        else tbl

-- let missing_fn_entries = filter (`notElem` functions) methods
--              in if not (null missing_fn_entries)
--                 then error ("Inconsistency in Raw Adaption Table: The following methods\n" 
--                             ++ "don't have a Function entry: " ++ show missing_fn_entries)
--                 else tbl
                 
    where
      isClassEntry (Haskell _ (Class _))   = True
      isClassEntry _                       = False
      isFunctionEntry (Haskell _ Function) = True
      isFunctionEntry _                    = False
      

makeGlobalEnv_FromAdaptionTable :: AdaptionTable -> Env.GlobalE
makeGlobalEnv_FromAdaptionTable adaptionTable
    = Env.makeGlobalEnv importNothing exportAll (hskIdentifiers adaptionTable)
    where importNothing = const []
          exportAll     = const True
          hskIdentifiers (AdaptionTable mapping) = map fst mapping

filterAdaptionTable :: ((Env.Identifier, Env.Identifier) -> Bool) -> AdaptionTable -> AdaptionTable
filterAdaptionTable predicate (AdaptionTable entries)
    = AdaptionTable (filter predicate entries)

parseEntry :: AdaptionEntry -> Env.Identifier

parseEntry (Haskell raw_identifier op)
    = let (moduleID, identifierID) = parseRawIdentifier raw_identifier
          op' = (case op of Function -> fromMaybe Function (lookup raw_identifier hsk_infix_ops)
                            etc      -> etc)
      in makeIdentifier op' moduleID identifierID Env.EnvTyNone
parseEntry (Isabelle raw_identifier op)
    -- the raw identifier may look like "Datatype.option.None", where
    -- "Datatype" is the ModuleID, and "None" is the real identifier,
    -- and "option" basically noisy garbage.
    = let (moduleID, identifierID) = parseRawIdentifier raw_identifier
          moduleID'                = (case wordsBy (== '.') moduleID of 
                                        []  -> moduleID
                                        m:_ -> m)
      in makeIdentifier op moduleID' identifierID Env.EnvTyNone

parseRawIdentifier :: String -> (String, String)
parseRawIdentifier string
    = if '(' `elem` string 
      then let (modul, identifier) = break (== '(') string -- "Prelude.(:)"
           in assert (last modul == '.' && 
                      last identifier == ')') 
                 $ (init modul, tail (init identifier))
      else let parts      = wordsBy (== '.') string
               identifier = last parts
               modul      = concat $ intersperse "." (init parts)
           in (modul, identifier)

makeIdentifier :: OpKind -> Env.ModuleID -> Env.IdentifierID -> Env.EnvType -> Env.Identifier
makeIdentifier Variable m identifier t
    = Env.Constant $ Env.Variable $ Env.makeLexInfo m identifier t
makeIdentifier Function m identifier t
    = Env.Constant $ Env.Function $ Env.makeLexInfo m identifier t
makeIdentifier (UnaryOp prio) m identifier t
    = Env.Constant $ Env.UnaryOp (Env.makeLexInfo m identifier t) prio
makeIdentifier (InfixOp assoc prio) m identifier t
    = Env.Constant $ Env.InfixOp (Env.makeLexInfo m identifier t) (transformAssoc assoc) prio
makeIdentifier (Class classinfo) m identifier t
    = let supers  = map (Env.EnvUnqualName . snd . parseRawIdentifier) (superclasses classinfo)
          meths   = map (\(n, tstr) -> let t = Env.fromHsk (parseHsType tstr)
                                       in makeTypeAnnot (Env.makeLexInfo m n t))
                        (methods classinfo)
          classV  = Env.EnvUnqualName (classVar classinfo)
      in 
        Env.Type $ Env.Class (Env.makeLexInfo m identifier t)
                             (Env.makeClassInfo supers meths classV)
makeIdentifier Type m identifier t
    = Env.Type $ Env.Data (Env.makeLexInfo m identifier t) []

makeTypeAnnot :: Env.LexInfo -> Env.Identifier
makeTypeAnnot lexinfo = Env.Constant (Env.TypeAnnotation lexinfo)

parseHsType :: String -> HsType
parseHsType string
    = let (ParseOk (HsModule _ _ _ _ [HsTypeSig _ _ t])) 
              = parseFileContents ("__foo__ :: " ++ string)
      in t

transformAssoc :: Assoc -> Env.EnvAssoc
transformAssoc RightAssoc = Env.EnvAssocRight
transformAssoc LeftAssoc  = Env.EnvAssocLeft
transformAssoc NoneAssoc  = Env.EnvAssocNone
