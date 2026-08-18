import Foundation

/// Markdown templates for the notes Hall-e creates. All Hall-e-managed sections
/// carry marker blocks so later merges are non-destructive.
enum NoteTemplates {
    static let meeting = """
    ---
    type: meeting
    date: {{date}}
    start: "{{start}}"
    end: "{{end}}"
    project: "{{project}}"
    source_account: "{{source_account}}"
    calendar: "{{calendar}}"
    attendees:{{attendees_yaml}}
    meeting_url: "{{meeting_url}}"
    recording_path: "{{recording_path}}"
    transcript_status: "{{transcript_status}}"
    classification_confidence: {{classification_confidence}}
    hall_e_event_id: "{{hall_e_event_id}}"
    tags:
      - meeting{{project_tag}}
    ---

    # {{title}}

    ## Context
    - Project: {{project}}
    - Calendar source: {{calendar}} ({{source_account}})
    - Attendees: {{attendees_inline}}
    - Meeting link: {{meeting_url}}

    ## Pre-meeting notes
    -

    ## Transcript
    <!-- hall-e:transcript:start -->
    <!-- transcript goes here -->
    <!-- hall-e:transcript:end -->

    ## Summary
    <!-- hall-e:summary:start -->
    <!-- hall-e:summary:end -->

    ## Decisions
    <!-- hall-e:decisions:start -->
    <!-- hall-e:decisions:end -->

    ## Action items
    <!-- hall-e:actions:start -->
    <!-- hall-e:actions:end -->

    ## Follow-ups
    <!-- hall-e:followups:start -->
    <!-- hall-e:followups:end -->

    ## Links
    <!-- hall-e:links:start -->
    {{links}}
    <!-- hall-e:links:end -->
    """

    /// WhatsApp call note — same structure/markers as `meeting` (so the same
    /// transcript/summary/action merges work) but typed as a call.
    static let call = """
    ---
    type: call
    date: {{date}}
    start: "{{start}}"
    end: "{{end}}"
    project: "{{project}}"
    source: "WhatsApp"
    recording_path: "{{recording_path}}"
    transcript_status: "{{transcript_status}}"
    classification_confidence: {{classification_confidence}}
    hall_e_event_id: "{{hall_e_event_id}}"
    tags:
      - call{{project_tag}}
    ---

    # {{title}}

    ## Context
    - Project: {{project}}
    - Source: WhatsApp call

    ## Transcript
    <!-- hall-e:transcript:start -->
    <!-- transcript goes here -->
    <!-- hall-e:transcript:end -->

    ## Summary
    <!-- hall-e:summary:start -->
    <!-- hall-e:summary:end -->

    ## Decisions
    <!-- hall-e:decisions:start -->
    <!-- hall-e:decisions:end -->

    ## Action items
    <!-- hall-e:actions:start -->
    <!-- hall-e:actions:end -->

    ## Follow-ups
    <!-- hall-e:followups:start -->
    <!-- hall-e:followups:end -->

    ## Links
    <!-- hall-e:links:start -->
    {{links}}
    <!-- hall-e:links:end -->
    """

    static let project = """
    ---
    type: project
    project: {{project}}
    tags:
      - project
    ---

    # {{project}}

    ## Overview
    -

    ## Hall-e Assistant
    <!-- hall-e:assistant-brief:start -->
    _No generated project brief yet._
    <!-- hall-e:assistant-brief:end -->

    ## Meetings
    See [[{{project}}/Meetings|Meetings index]].
    """

    static let meetingsIndex = """
    ---
    type: project-meetings-index
    project: {{project}}
    ---

    # {{project}} — Meetings

    <!-- hall-e:meetings-index:start -->
    <!-- hall-e:meetings-index:end -->
    """

    static let daily = """
    ---
    type: daily
    date: {{date}}
    ---

    # {{date}}

    ## Meetings
    <!-- hall-e:daily-meetings:start -->
    <!-- hall-e:daily-meetings:end -->
    """

    static let inboxIndex = """
    ---
    type: inbox
    ---

    # Unclassified Meetings

    Meetings Hall-e couldn't confidently classify. Assign each to a project.

    <!-- hall-e:meetings-index:start -->
    <!-- hall-e:meetings-index:end -->
    """
}
