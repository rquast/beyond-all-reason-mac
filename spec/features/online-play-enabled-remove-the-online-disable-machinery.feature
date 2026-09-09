@done
@launcher
@build-release
@launcher-content
@LAUNCH-002
Feature: Online play enabled: remove the online-disable machinery
  """
  Build pipeline: packaging/release-build.sh loses the ENABLE_ONLINE knob, the
  --enable-online/--disable-online flags, the BAR_ONLINE env, and the Python
  neuter block that rewrote chobby_config.json's server to
  online-play-disabled.localhost:1; the Makefile loses its ONLINE variable /
  ONLINE_ARG wiring; README.md drops the 'online play disabled' release note.
  The chobby_config.json extraction (extract-launcher-config.py) is the only
  writer of the lobby endpoint.

  Launcher: the .online-play-disabled marker gate, the 'ONLINE PLAY IS
  DISABLED' --notice text and its NOTICE_VERSION/.notice-ack are removed from
  packaging/launcher.sh; the remote message-check and content-disclaimer
  (--server) paths stay untouched. consent-dialog.swift's --notice mode was
  retired together with its last caller (the launcher notice), and the test
  harnesses (packaging/test/launcher-test.sh, dialog-center-test.sh) lost
  their online-disabled cases in the same change.
  """

  Background: User Story
    As a BAR macOS player
    I want to start the game and connect to the official lobby / online play
    So that I can play internet games against the community with no build flag or opt-in step

  Scenario: A packaged build connects to the official lobby
    Given the bar-profile bundle is staged from the canonical dist_cfg launcher config
    When the launcher deploys chobby_config.json for a player session
    Then the deployed server address and port are exactly the ones from the canonical dist_cfg
    And the lobby server endpoint is not the unreachable loopback endpoint online-play-disabled.localhost:1
    And the staged Resources contain no .online-play-disabled marker file

  Scenario: First launch of a packaged build shows no online-disabled notice
    Given a fresh machine writedir and a bundle whose Resources still carry the legacy .online-play-disabled marker
    When a player launches the game for the first time
    Then the "ONLINE PLAY IS DISABLED" notice is not shown and no .notice-ack file is written
    And the remote message check still runs
    And the content-disclaimer still runs
    And the engine launches

  Scenario: The build pipeline has no online-disable switch
    Given the build pipeline is the packaged Makefile and release-build.sh
    When the maintainer builds the app with plain `make app` and never mentions online play
    Then a plain invocation of release-build.sh is accepted as usual and proceeds to the engine build step
    And release-build.sh rejects --enable-online and --disable-online as unknown arguments
    And the BAR_ONLINE environment variable has no effect
    And the Makefile documents no ONLINE variable
    And the README no longer instructs building with online play disabled

  Scenario: The online-disabled notice machinery is gone from the launcher
    Given the launcher source and its test harnesses
    When the maintainer inspects the packaging layer
    Then launcher.sh contains no marker gate, notice text, or .notice-ack machinery
    And consent-dialog.swift has no --notice mode
    And launcher-test.sh has no case gating a notice on the marker
    And dialog-center-test.sh has no online-disabled notice geometry case
