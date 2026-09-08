@done
@PLAT-003
@log-backend @wip @log @critical
Feature: log-repeat-coalescer

  """
  The generic near-identical repeat coalescer lives in System/Log/Backend.cpp (commit b408ad288d), the one choke point every log record passes through. It keeps up to NUM_SLOTS=8 tracked signature slots (section + message with each numeric token collapsed to '#', so lines that differ only in numbers share a signature). When a record matches a recent slot it is suppressed, counted, and every ROLLUP_EVERY=100th suppression (plus any residual tail via log_backend_flushRepeats) emits a 'previous line repeated N more time(s) [section: X]' rollup at the original level. A new/distinct line passes through in full and claims a slot (free, else least-recently-used); evicting a slot with a pending tail flushes that tail first. Decisions are made under a mutex but emits happen outside it so a re-entrant sink cannot deadlock. Two independent flood sources interleave without breaking each other's run because of the 8 slots. Punctuation-only runs (no digit) stay verbatim in the signature so structurally-different lines remain distinct.
  """

  Background: User Story
    As a support engineer collecting a bug report from a BAR player on a long session
    I want the player's infolog.txt to stay small enough to attach
    So that the log remains a useful diagnostic instead of a hundreds-of-MB flood of structurally-identical lines


  Scenario: A flood of structurally-identical lines is collapsed into a periodic rollup
    Given the log backend coalescer is active and exact-duplicate suppression is disabled
    When the engine logs one stall warning, then 101 more with only their numbers changing
    Then exactly one full stall warning is emitted, and the 100 suppressed duplicates are accounted for in a 'previous line repeated N more time(s)' rollup carrying the stall section


  Scenario: Two interleaved flood patterns stay distinct
    Given the log backend coalescer is active and exact-duplicate suppression is disabled
    When the engine logs five input-motion lines and five stall draw-gap lines interleaved, each with only its numbers changing
    Then each pattern passes through exactly once, and its four suppressed repeats are accounted in its own rollup carrying its own section


  Scenario: Structurally different lines are not merged
    Given the log backend coalescer is active and exact-duplicate suppression is disabled
    When the engine logs two texture-load lines from the same section that differ by a non-numeric word
    Then both lines pass through in full and no repeat rollup is emitted


  Scenario: Structurally different lines stay distinct even with numeric noise
    Given the log backend coalescer is active and exact-duplicate suppression is disabled
    When the engine logs two path lines that differ by a non-numeric word while their trailing numbers also differ
    Then both lines pass through in full and no repeat rollup is emitted

