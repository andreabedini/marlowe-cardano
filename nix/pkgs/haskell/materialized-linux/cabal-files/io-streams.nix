{ system
  , compiler
  , flags
  , pkgs
  , hsPkgs
  , pkgconfPkgs
  , errorHandler
  , config
  , ... }:
  ({
    flags = { nointeractivetests = false; zlib = true; network = true; };
    package = {
      specVersion = "1.10";
      identifier = { name = "io-streams"; version = "1.5.2.2"; };
      license = "BSD-3-Clause";
      copyright = "";
      maintainer = "Gregory Collins <greg@gregorycollins.net>";
      author = "";
      homepage = "";
      url = "";
      synopsis = "Simple, composable, and easy-to-use stream I/O";
      description = "/Overview/\n\nThe io-streams library contains simple and easy-to-use primitives for I/O\nusing streams. Most users will want to import the top-level convenience\nmodule \"System.IO.Streams\", which re-exports most of the library:\n\n@\nimport           System.IO.Streams (InputStream, OutputStream)\nimport qualified System.IO.Streams as Streams\n@\n\nFor first-time users, @io-streams@ comes with an included tutorial, which can\nbe found in the \"System.IO.Streams.Tutorial\" module.\n\n/Features/\n\nThe @io-streams@ user API has two basic types: @InputStream a@ and\n@OutputStream a@, and three fundamental I/O primitives:\n\n@\n\\-\\- read an item from an input stream\nStreams.read :: InputStream a -> IO (Maybe a)\n\n\\-\\- push an item back to an input stream\nStreams.unRead :: a -> InputStream a -> IO ()\n\n\\-\\- write to an output stream\nStreams.write :: Maybe a -> OutputStream a -> IO ()\n@\n\nStreams can be transformed by composition and hooked together with provided combinators:\n\n@\nghci> Streams.fromList [1,2,3::Int] >>= Streams.map (*10) >>= Streams.toList\n[10,20,30]\n@\n\nStream composition leaves the original stream accessible:\n\n@\nghci> input \\<- Streams.fromByteString \\\"long string\\\"\nghci> wrapped \\<- Streams.takeBytes 4 input\nghci> Streams.read wrapped\nJust \\\"long\\\"\nghci> Streams.read wrapped\nNothing\nghci> Streams.read input\nJust \\\" string\\\"\n@\n\nSimple types and operations in the IO monad mean straightforward and simple\nexception handling and resource cleanup using Haskell standard library\nfacilities like 'Control.Exception.bracket'.\n\n@io-streams@ comes with:\n\n* functions to use files, handles, concurrent channels, sockets, lists,\nvectors, and more as streams.\n\n* a variety of combinators for wrapping and transforming streams, including\ncompression and decompression using zlib, controlling precisely how many\nbytes are read from or written to a stream, buffering output using\nbytestring builders, folds, maps, filters, zips, etc.\n\n* support for parsing from streams using @attoparsec@.\n\n* support for spawning processes and communicating with them using streams.";
      buildType = "Simple";
      };
    components = {
      "library" = {
        depends = (([
          (hsPkgs."base" or (errorHandler.buildDepError "base"))
          (hsPkgs."attoparsec" or (errorHandler.buildDepError "attoparsec"))
          (hsPkgs."bytestring" or (errorHandler.buildDepError "bytestring"))
          (hsPkgs."primitive" or (errorHandler.buildDepError "primitive"))
          (hsPkgs."process" or (errorHandler.buildDepError "process"))
          (hsPkgs."text" or (errorHandler.buildDepError "text"))
          (hsPkgs."time" or (errorHandler.buildDepError "time"))
          (hsPkgs."transformers" or (errorHandler.buildDepError "transformers"))
          (hsPkgs."vector" or (errorHandler.buildDepError "vector"))
          ] ++ (pkgs.lib).optional (!(compiler.isGhc && (compiler.version).ge "7.8")) (hsPkgs."bytestring-builder" or (errorHandler.buildDepError "bytestring-builder"))) ++ (pkgs.lib).optional (flags.zlib) (hsPkgs."zlib-bindings" or (errorHandler.buildDepError "zlib-bindings"))) ++ (pkgs.lib).optional (flags.network) (hsPkgs."network" or (errorHandler.buildDepError "network"));
        buildable = true;
        };
      tests = {
        "testsuite" = {
          depends = (([
            (hsPkgs."base" or (errorHandler.buildDepError "base"))
            (hsPkgs."attoparsec" or (errorHandler.buildDepError "attoparsec"))
            (hsPkgs."bytestring" or (errorHandler.buildDepError "bytestring"))
            (hsPkgs."deepseq" or (errorHandler.buildDepError "deepseq"))
            (hsPkgs."directory" or (errorHandler.buildDepError "directory"))
            (hsPkgs."filepath" or (errorHandler.buildDepError "filepath"))
            (hsPkgs."mtl" or (errorHandler.buildDepError "mtl"))
            (hsPkgs."primitive" or (errorHandler.buildDepError "primitive"))
            (hsPkgs."process" or (errorHandler.buildDepError "process"))
            (hsPkgs."text" or (errorHandler.buildDepError "text"))
            (hsPkgs."time" or (errorHandler.buildDepError "time"))
            (hsPkgs."transformers" or (errorHandler.buildDepError "transformers"))
            (hsPkgs."vector" or (errorHandler.buildDepError "vector"))
            (hsPkgs."HUnit" or (errorHandler.buildDepError "HUnit"))
            (hsPkgs."QuickCheck" or (errorHandler.buildDepError "QuickCheck"))
            (hsPkgs."test-framework" or (errorHandler.buildDepError "test-framework"))
            (hsPkgs."test-framework-hunit" or (errorHandler.buildDepError "test-framework-hunit"))
            (hsPkgs."test-framework-quickcheck2" or (errorHandler.buildDepError "test-framework-quickcheck2"))
            ] ++ (pkgs.lib).optionals (flags.zlib) [
            (hsPkgs."zlib-bindings" or (errorHandler.buildDepError "zlib-bindings"))
            (hsPkgs."zlib" or (errorHandler.buildDepError "zlib"))
            ]) ++ (pkgs.lib).optional (flags.network) (hsPkgs."network" or (errorHandler.buildDepError "network"))) ++ (pkgs.lib).optional (!(compiler.isGhc && (compiler.version).ge "7.8")) (hsPkgs."bytestring-builder" or (errorHandler.buildDepError "bytestring-builder"));
          buildable = true;
          };
        };
      };
    } // {
    src = (pkgs.lib).mkDefault (pkgs.fetchurl {
      url = "http://hackage.haskell.org/package/io-streams-1.5.2.2.tar.gz";
      sha256 = "d365d5051696c15414ebe23749fc67475a532234b7c7d77060323d149a8fc4fe";
      });
    }) // {
    package-description-override = "Name:                io-streams\nVersion:             1.5.2.2\nLicense:             BSD3\nLicense-file:        LICENSE\nCategory:            Data, Network, IO-Streams\nBuild-type:          Simple\nMaintainer:          Gregory Collins <greg@gregorycollins.net>\nCabal-version:       >= 1.10\nSynopsis:            Simple, composable, and easy-to-use stream I/O\nTested-With:\n  GHC == 9.4.1\n  GHC == 9.2.4\n  GHC == 9.0.2\n  GHC == 8.10.7\n  GHC == 8.8.4\n  GHC == 8.6.5\n  GHC == 8.4.4\n  GHC == 8.2.2\n  GHC == 8.0.2\n  GHC == 7.10.3\n  GHC == 7.8.4\n  GHC == 7.6.3\n  GHC == 7.4.2\n\nBug-Reports:         https://github.com/snapframework/io-streams/issues\nDescription:\n  /Overview/\n  .\n  The io-streams library contains simple and easy-to-use primitives for I/O\n  using streams. Most users will want to import the top-level convenience\n  module \"System.IO.Streams\", which re-exports most of the library:\n  .\n  @\n  import           System.IO.Streams (InputStream, OutputStream)\n  import qualified System.IO.Streams as Streams\n  @\n  .\n  For first-time users, @io-streams@ comes with an included tutorial, which can\n  be found in the \"System.IO.Streams.Tutorial\" module.\n  .\n  /Features/\n  .\n  The @io-streams@ user API has two basic types: @InputStream a@ and\n  @OutputStream a@, and three fundamental I/O primitives:\n  .\n  @\n  \\-\\- read an item from an input stream\n  Streams.read :: InputStream a -> IO (Maybe a)\n  .\n  \\-\\- push an item back to an input stream\n  Streams.unRead :: a -> InputStream a -> IO ()\n  .\n  \\-\\- write to an output stream\n  Streams.write :: Maybe a -> OutputStream a -> IO ()\n  @\n  .\n  Streams can be transformed by composition and hooked together with provided combinators:\n  .\n  @\n  ghci> Streams.fromList [1,2,3::Int] >>= Streams.map (*10) >>= Streams.toList\n  [10,20,30]\n  @\n  .\n  Stream composition leaves the original stream accessible:\n  .\n  @\n  ghci> input \\<- Streams.fromByteString \\\"long string\\\"\n  ghci> wrapped \\<- Streams.takeBytes 4 input\n  ghci> Streams.read wrapped\n  Just \\\"long\\\"\n  ghci> Streams.read wrapped\n  Nothing\n  ghci> Streams.read input\n  Just \\\" string\\\"\n  @\n  .\n  Simple types and operations in the IO monad mean straightforward and simple\n  exception handling and resource cleanup using Haskell standard library\n  facilities like 'Control.Exception.bracket'.\n  .\n  @io-streams@ comes with:\n  .\n    * functions to use files, handles, concurrent channels, sockets, lists,\n      vectors, and more as streams.\n  .\n    * a variety of combinators for wrapping and transforming streams, including\n      compression and decompression using zlib, controlling precisely how many\n      bytes are read from or written to a stream, buffering output using\n      bytestring builders, folds, maps, filters, zips, etc.\n  .\n    * support for parsing from streams using @attoparsec@.\n  .\n    * support for spawning processes and communicating with them using streams.\n\nExtra-Source-Files:  CONTRIBUTORS README.md changelog.md\n\nFlag NoInteractiveTests\n  Description: Do not run interactive tests\n  Default: False\n\nFlag Zlib\n  Description: Include zlib support\n  Default: True\n  Manual: True\n\nFlag Network\n  Description: Include network support\n  Default: True\n  Manual: True\n\n------------------------------------------------------------------------------\nLibrary\n  hs-source-dirs:    src\n  Default-language:  Haskell2010\n\n  ghc-options:       -Wall -fwarn-tabs -funbox-strict-fields\n                     -fno-warn-unused-do-bind\n\n  Exposed-modules:   System.IO.Streams,\n                     System.IO.Streams.Attoparsec,\n                     System.IO.Streams.Attoparsec.ByteString,\n                     System.IO.Streams.Attoparsec.Text,\n                     System.IO.Streams.Builder,\n                     System.IO.Streams.ByteString,\n                     System.IO.Streams.Combinators,\n                     System.IO.Streams.Concurrent,\n                     System.IO.Streams.Core,\n                     System.IO.Streams.Debug,\n                     System.IO.Streams.Handle,\n                     System.IO.Streams.File,\n                     System.IO.Streams.List,\n                     System.IO.Streams.Process,\n                     System.IO.Streams.Text,\n                     System.IO.Streams.Vector,\n                     System.IO.Streams.Internal,\n                     System.IO.Streams.Tutorial\n\n  Other-modules:     System.IO.Streams.Internal.Attoparsec,\n                     System.IO.Streams.Internal.Search\n\n  Build-depends:     base               >= 4     && <5,\n                     attoparsec         >= 0.10  && <0.15,\n                     bytestring         >= 0.9   && <0.12,\n                     primitive          >= 0.2   && <0.8,\n                     process            >= 1.1   && <1.7,\n                     text               >=0.10   && <1.3  || >= 2.0 && <2.1,\n                     time               >= 1.2   && <1.13,\n                     transformers       >= 0.2   && <0.7,\n                     vector             >= 0.7   && <0.14\n\n  if !impl(ghc >= 7.8)\n    Build-depends:   bytestring-builder >= 0.10  && <0.11\n\n  if impl(ghc >= 7.2)\n    other-extensions: Trustworthy\n\n  if flag(Zlib)\n    Exposed-modules: System.IO.Streams.Zlib\n    Build-depends:   zlib-bindings      >= 0.1   && <0.2\n    cpp-options:     -DENABLE_ZLIB\n\n  if flag(Network)\n    Exposed-modules: System.IO.Streams.Network\n    Other-modules:   System.IO.Streams.Internal.Network\n    Build-depends:   network            >= 2.3   && <3.2\n    cpp-options:     -DENABLE_NETWORK\n\n  other-extensions:\n    BangPatterns,\n    CPP,\n    DeriveDataTypeable,\n    FlexibleContexts,\n    FlexibleInstances,\n    GeneralizedNewtypeDeriving,\n    MultiParamTypeClasses,\n    OverloadedStrings,\n    RankNTypes,\n    TypeSynonymInstances\n\n\n------------------------------------------------------------------------------\nTest-suite testsuite\n  Type:              exitcode-stdio-1.0\n  hs-source-dirs:    src test\n  Main-is:           TestSuite.hs\n  Default-language:  Haskell2010\n\n  Other-modules:     System.IO.Streams.Tests.Attoparsec.ByteString,\n                     System.IO.Streams.Tests.Attoparsec.Text,\n                     System.IO.Streams.Tests.Builder,\n                     System.IO.Streams.Tests.ByteString,\n                     System.IO.Streams.Tests.Combinators,\n                     System.IO.Streams.Tests.Common,\n                     System.IO.Streams.Tests.Concurrent,\n                     System.IO.Streams.Tests.Debug,\n                     System.IO.Streams.Tests.File,\n                     System.IO.Streams.Tests.Handle,\n                     System.IO.Streams.Tests.Internal,\n                     System.IO.Streams.Tests.List,\n                     System.IO.Streams.Tests.Process,\n                     System.IO.Streams.Tests.Text,\n                     System.IO.Streams.Tests.Vector,\n                     System.IO.Streams,\n                     System.IO.Streams.Attoparsec.ByteString,\n                     System.IO.Streams.Attoparsec.Text,\n                     System.IO.Streams.Builder,\n                     System.IO.Streams.ByteString,\n                     System.IO.Streams.Combinators,\n                     System.IO.Streams.Concurrent,\n                     System.IO.Streams.Core,\n                     System.IO.Streams.Debug,\n                     System.IO.Streams.Handle,\n                     System.IO.Streams.File,\n                     System.IO.Streams.List,\n                     System.IO.Streams.Process,\n                     System.IO.Streams.Text,\n                     System.IO.Streams.Vector,\n                     System.IO.Streams.Internal,\n                     System.IO.Streams.Internal.Attoparsec,\n                     System.IO.Streams.Internal.Search\n\n\n  ghc-options:       -Wall -fwarn-tabs -funbox-strict-fields -threaded\n                     -fno-warn-unused-do-bind\n\n  if !os(windows) && !flag(NoInteractiveTests)\n    cpp-options: -DENABLE_PROCESS_TESTS\n\n  if flag(Zlib)\n    Other-modules:   System.IO.Streams.Tests.Zlib,\n                     System.IO.Streams.Zlib\n    Build-depends:   zlib-bindings,\n                     zlib                       >= 0.5      && <0.7\n    cpp-options:     -DENABLE_ZLIB\n\n  if flag(Network)\n    Other-modules:   System.IO.Streams.Internal.Network,\n                     System.IO.Streams.Network,\n                     System.IO.Streams.Tests.Network\n    Build-depends:   network\n    cpp-options:     -DENABLE_NETWORK\n\n  Build-depends:     base,\n                     attoparsec,\n                     bytestring,\n                     deepseq            >= 1.2   && <1.5,\n                     directory          >= 1.1   && <2,\n                     filepath           >= 1.2   && <2,\n                     mtl                >= 2     && <3,\n                     primitive,\n                     process,\n                     text,\n                     time,\n                     transformers,\n                     vector,\n\n                     HUnit                      >= 1.2      && <2,\n                     QuickCheck                 >= 2.3.0.2  && <3,\n                     test-framework             >= 0.6      && <0.9,\n                     test-framework-hunit       >= 0.2.7    && <0.4,\n                     test-framework-quickcheck2 >= 0.2.12.1 && <0.4\n\n  if !impl(ghc >= 7.8)\n    Build-depends:   bytestring-builder\n\n  if impl(ghc >= 7.2)\n    other-extensions: Trustworthy\n\n  other-extensions:\n    BangPatterns,\n    CPP,\n    DeriveDataTypeable,\n    FlexibleInstances,\n    GeneralizedNewtypeDeriving,\n    MultiParamTypeClasses,\n    OverloadedStrings,\n    RankNTypes\n\nsource-repository head\n  type:     git\n  location: https://github.com/snapframework/io-streams.git\n";
    }