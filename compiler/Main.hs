-- Copyright (c) Microsoft. All rights reserved.
-- Licensed under the MIT license. See LICENSE file in the project root for full license information.

{-# LANGUAGE RecordWildCards #-}

import System.Environment (getArgs, withArgs)
import System.Directory
import System.FilePath
import Data.Maybe
import Data.Monoid
import qualified Data.Foldable as F
import Control.Monad
import Prelude
import Control.Concurrent.Async
import GHC.Conc (getNumProcessors, setNumCapabilities)
import Data.Text.Lazy (Text)
import qualified Data.Text.Lazy.IO as L
import Data.Aeson (encode)
import qualified Data.ByteString.Lazy as BL
import Language.Bond.Syntax.Types (Bond(..), Declaration(..), Import, Type(..))
import Language.Bond.Syntax.JSON()
import Language.Bond.Syntax.SchemaDef
import Language.Bond.Codegen.Util
import Language.Bond.Codegen.Templates
import Language.Bond.Codegen.TypeMapping
import Options
import IO

type Template = MappingContext -> String -> [Import] -> [Declaration] -> (String, Text)

main :: IO()
main = do
    args <- getArgs
    options <- (if null args then withArgs ["--help=all"] else id) getOptions
    setJobs $ jobs options
    case options of
        Cpp {..}    -> cppCodegen options
        Cs {..}     -> csCodegen options
        Schema {..} -> writeSchema options
        _           -> print options

setJobs :: Maybe Int -> IO ()
setJobs Nothing = return ()
setJobs (Just n)
    | n > 0     = setNumCapabilities n
    | otherwise = do
        numProc <- getNumProcessors
        -- if n is less than 0 use that many fewer jobs than processors
        setNumCapabilities $ max 1 (numProc + n)

concurrentlyFor_ :: [a] -> (a -> IO b) -> IO ()
concurrentlyFor_ = (void .) . flip mapConcurrently


writeSchema :: Options -> IO()
writeSchema Schema {..} =
    concurrentlyFor_ files $ \file -> do
        let fileName = takeBaseName file
        bond <- parseFile import_dir file
        if runtime_schema then
                forM_ (bondDeclarations bond) (writeSchemaDef fileName)
            else
                BL.writeFile (output_dir </> fileName <.> "json") $ encode bond
  where
    writeSchemaDef fileName s@Struct{..} | null declParams =
        BL.writeFile (output_dir </> fileName <.> declName <.> "json") $ encodeSchemaDef $ BT_UserDefined s []
    writeSchemaDef _ _ = return ()

writeSchema _ = error "writeSchema: impossible happened."

cppCodegen :: Options -> IO()
cppCodegen options@Cpp {..} = do
    let typeMapping = maybe cppTypeMapping cppCustomAllocTypeMapping allocator
    concurrentlyFor_ files $ codeGen options typeMapping templates
  where
    applyProto = map snd $ filter (enabled apply) protocols
    enabled a p = null a || fst p `elem` a
    protocols =
        [ (Compact, ProtocolReader " ::bond::CompactBinaryReader< ::bond::InputBuffer>")
        , (Compact, ProtocolWriter " ::bond::CompactBinaryWriter< ::bond::OutputBuffer>")
        , (Compact, ProtocolWriter " ::bond::CompactBinaryWriter< ::bond::CompactBinaryCounter::type>")
        , (Fast,    ProtocolReader " ::bond::FastBinaryReader< ::bond::InputBuffer>")
        , (Fast,    ProtocolWriter " ::bond::FastBinaryWriter< ::bond::OutputBuffer>")
        , (Simple,  ProtocolReader " ::bond::SimpleBinaryReader< ::bond::InputBuffer>")
        , (Simple,  ProtocolWriter " ::bond::SimpleBinaryWriter< ::bond::OutputBuffer>")
        ]
    templates = concat $ map snd $ filter fst codegen_templates
    codegen_templates = [ (core_enabled, core_files)
                        , (comm_enabled, [comm_h export_attribute, comm_cpp])
                        , (grpc_enabled, [grpc_h export_attribute])
                        ]
    core_files = [
          reflection_h export_attribute
        , types_h header enum_header allocator
        , types_cpp
        , apply_h applyProto export_attribute
        , apply_cpp applyProto
        ] <>
        [ enum_h | enum_header]
cppCodegen _ = error "cppCodegen: impossible happened."

csCodegen :: Options -> IO()
csCodegen options@Cs {..} = do
    concurrentlyFor_ files $ codeGen options typeMapping templates
  where
    typeMapping = if collection_interfaces
            then csCollectionInterfacesTypeMapping
            else csTypeMapping
    fieldMapping = if readonly_properties
            then ReadOnlyProperties
            else if fields
                 then PublicFields
                 else Properties
    templates = concat $ map snd $ filter fst codegen_templates
    codegen_templates = [ (structs_enabled, [types_cs Class fieldMapping])
                        , (comm_enabled, [comm_interface_cs, comm_proxy_cs, comm_service_cs])
                        , (grpc_enabled, [grpc_cs])
                        ]
csCodegen _ = error "csCodegen: impossible happened."

anyServiceInheritance :: [Declaration] -> Bool
anyServiceInheritance = getAny . F.foldMap serviceWithBase
  where
    serviceWithBase Service{..} = Any $ isJust serviceBase
    serviceWithBase _ = Any False

codeGen :: Options -> TypeMapping -> [Template] -> FilePath -> IO ()
codeGen options typeMapping templates file = do
    let outputDir = output_dir options
    let baseName = takeBaseName file
    aliasMapping <- parseAliasMappings $ using options
    namespaceMapping <- parseNamespaceMappings $ namespace options
    (Bond imports namespaces declarations) <- parseFile (import_dir options) file
    let mappingContext = MappingContext typeMapping aliasMapping namespaceMapping namespaces
    case (anyServiceInheritance declarations, service_inheritance_enabled options, grpc_enabled options, comm_enabled options) of
        (True, False, _, _)   -> fail "Use --enable-service-inheritance to enable service inheritance syntax."
        (True, True, True, _) -> fail "Service inheritance is not supported in gRPC codegen."
        (True, True, _, True) -> fail "Service inheritance is not supported in Comm codegen."
        _                     -> forM_ templates $ \template -> do
                                    let (suffix, code) = template mappingContext baseName imports declarations
                                    let fileName = baseName ++ suffix
                                    createDirectoryIfMissing True outputDir
                                    let content = if (no_banner options) then code else (commonHeader "//" fileName <> code)
                                    L.writeFile (outputDir </> fileName) content
