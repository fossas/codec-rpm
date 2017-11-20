sandbox:
	[ -d .cabal-sandbox ] || cabal sandbox init

hlint: sandbox
	[ -x .cabal-sandbox/bin/happy ] || cabal install happy
	[ -x .cabal-sandbox/bin/hlint ] || cabal install hlint
	cabal exec hlint .

tests: sandbox
	cabal install --dependencies-only --enable-tests --force-reinstalls
	cabal configure --enable-tests --enable-coverage --ghc-option=-DTEST
	cabal build
	cabal test --show-details=always

ci: hlint tests

ci_after_success:
	hpc-coveralls --display-report tests
