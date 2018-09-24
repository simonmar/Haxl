# Changes in version 2.0.1.1

  * Support for GHC 8.6.1
  * Bugfixes

# Changes in version 2.0.1.0

  * Exported MemoVar from Haxl.Core.Memo
  * Updated the facebook example
  * Fixed some links in the documentation
  * Bump some version bounds

# Changes in version 2.0.0.0

  * Completely rewritten internals to support arbitrarily overlapping
    I/O and computation.  Haxl no longer runs batches of I/O in
    "rounds", waiting for all the I/O to complete before resuming the
    computation. In Haxl 2, we can spawn I/O that returns results in
    the background and computation fragments are resumed when the
    values they depend on are available.  See
    `tests/FullyAsyncTest.hs` for an example.

  * A new `PerformFetch` constructor supports the new concurrency
    features: `BackgroundFetch`. The data source is expected to call
    `putResult` in the background on each `BlockedFetch` when its
    result is ready.

  * There is a generic `DataSource` implementation in
    `Haxl.DataSource.ConcurrentIO` for performing each I/O operation
    in a separate thread.

  * Lots of cleanup and refactoring of the APIs.

  * License changed from BSD+PATENTS to plain BSD3.

# Changes in version 0.5.1.0

  * 'pAnd' and 'pOr' were added
  * 'asyncFetchAcquireRelease' was added
  * 'cacheResultWithShow' was exposed
  * GHC 8.2.1 compatibility

# Changes in version 0.5.0.0
  * Rename 'Show1' to 'ShowP' ([#62](https://github.com/facebook/Haxl/issues/62))

# Changes in version 0.3.0.0

  * Some performance improvements, including avoiding quadratic
    slowdown with left-associated binds.

  * Documentation cleanup; Haxl.Core is the single entry point for the
    core and engine docs.

  * (>>) is now defined to be (*>), and therefore no longer forces
    sequencing.  This can have surprising consequences if you are
    using Haxl with side-effecting data sources, so watch out!

  * New function withEnv, for running a sub-computation in a local Env

  * Add a higher-level memoization API, see 'memo'

  * Show is no longer required for keys in cachedComputation

  * Exceptions now have `Eq` instances
