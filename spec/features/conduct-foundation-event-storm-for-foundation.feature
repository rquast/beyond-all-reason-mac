@foundation
@project
@FOUND-001
Feature: Conduct Foundation Event Storm for Foundation
  """
  Foundation event storm is stored in spec/foundation.json under eventStorm: 4 bounded contexts (Deterministic Simulation, Native Graphics & Present, Build & Release Pipeline, Content Distribution & Launcher) with aggregates SyncedState, PresentFrame, ReleaseArtifact, GameContent; domain events SyncGatePassed/SyncGateFailed/EngineVersionPinned, FramePresented/DriverIdentityVerified, ArtifactBuilt/ReleaseCertified; command RunStreflopSyncTest.
  """

  # ========================================
  # EXAMPLE MAPPING CONTEXT
  # ========================================
  #
  # BUSINESS RULES:
  #   1. Foundation event storm captures the 4 bounded contexts (Deterministic Simulation, Native Graphics & Present, Build & Release Pipeline, Content Distribution & Launcher), 4 aggregates, and the core domain events
  #
  # EXAMPLES:
  #   1. spec/foundation.json lists the 4 bounded contexts with aggregates: SyncedState, PresentFrame, ReleaseArtifact, GameContent
  #   2. show-foundation event-storm view shows the 4 bounded contexts, their aggregates (SyncedState, PresentFrame, ReleaseArtifact, GameContent), and the domain events (SyncGatePassed, FramePresented, ReleaseCertified)
  #
  # ========================================
  Background: User Story
    As a port maintainer
    I want to map the bounded contexts, aggregates, domain events, and commands of this macOS engine port
    So that the project foundation reflects the real domain so specs and tags stay consistent

  Scenario: Foundation event storm captures the bounded contexts and aggregates
    Given a finalized foundation exists
    When the maintainer runs show-foundation-event-storm
    Then the storm shows the 4 bounded contexts (Deterministic Simulation, Native Graphics & Present, Build & Release Pipeline, Content Distribution & Launcher) with their aggregates SyncedState, PresentFrame, ReleaseArtifact, GameContent

  Scenario: Foundation event storm captures the core domain events and commands
    Given a finalized foundation exists
    When the maintainer inspects the event storm domain events
    Then the storm shows domain events (SyncGatePassed, SyncGateFailed, EngineVersionPinned, FramePresented, DriverIdentityVerified, ArtifactBuilt, ReleaseCertified) and the RunStreflopSyncTest command
