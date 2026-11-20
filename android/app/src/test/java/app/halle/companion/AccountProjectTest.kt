package app.halle.companion

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.util.UUID

class AccountProjectTest {
    @get:Rule val tmp = TemporaryFolder()
    private val project = AccountProject(UUID.randomUUID(), "Synthetic design")
    private fun meeting(p: AccountProject) = JSONObject().put("project", p.json())

    @Test fun titleOnlyEditRetainsAnOrphanForConflictRecoveryAndOmitsItFromTheRequest() {
        val before = JSONObject().put("title", "Revised synthetic title")
        stageProject(before, edit = null, previous = project)
        val restarted = JSONObject(before.toString())
        assertEquals(project, pendingProject(restarted, current = null))
        val sent = meetingRequest(restarted.put("problem", 409).put("localNotes", "Synthetic private note"))
        assertFalse(sent.has("project"))
        assertFalse(sent.has("projectAtEdit"))
        assertFalse(sent.has("problem"))
        assertFalse(sent.has("localNotes"))
        assertTrue(projectSelectionAccepted(restarted, JSONObject()))

        val oldClient = JSONObject().put("title", "Legacy")
        assertEquals(project, pendingProject(oldClient, meeting(project)))
        assertFalse(meetingRequest(oldClient).has("project"))
        val unassigned = JSONObject()
        stageProject(unassigned, edit = null, previous = null)
        assertNull(pendingProject(unassigned, meeting(project)))
    }

    @Test fun explicitPhoneAssignmentSurvivesRestartAndAcceptsTheAccountNameForItsStableId() {
        val file = tmp.newFile()
        val edit = JSONObject().put("mutationId", UUID.randomUUID().toString())
        stageProject(edit, ProjectChange(project), previous = null)
        file.writeText(edit.toString())
        val retry = JSONObject(file.readText())
        assertEquals(edit.getString("mutationId"), retry.getString("mutationId"))
        assertEquals(project, AccountProject.read(meetingRequest(retry).getJSONObject("project")))
        assertFalse(projectSelectionAccepted(retry, JSONObject()))
        val canonical = project.copy(name = "Server-side original name")
        assertTrue(projectSelectionAccepted(retry, meeting(canonical)))
        assertEquals(listOf(canonical), accountProjects(listOf(meeting(canonical)), listOf(retry)))
    }

    @Test fun explicitRemovalUsesJsonNullAndDoesNotReinheritAnEarlierProject() {
        val edit = JSONObject()
        stageProject(edit, ProjectChange(null), project)
        val sent = meetingRequest(JSONObject(edit.toString()))
        assertTrue(sent.has("project"))
        assertTrue(sent.isNull("project"))
        assertNull(pendingProject(edit, meeting(project)))
        assertFalse(projectSelectionAccepted(edit, meeting(project)))
        assertTrue(projectSelectionAccepted(edit, JSONObject().put("project", JSONObject.NULL)))
    }

    @Test fun newProjectNamesMatchServerLimits() {
        assertThrows(IllegalArgumentException::class.java) { AccountProject(UUID.randomUUID(), "   ") }
        assertThrows(IllegalArgumentException::class.java) { AccountProject(UUID.randomUUID(), "abc\tdef") }
        assertThrows(IllegalArgumentException::class.java) { AccountProject(UUID.randomUUID(), "A".repeat(121)) }
        assertEquals(120, AccountProject(UUID.randomUUID(), "A".repeat(120)).name.length)
    }

    @Test fun projectChoicesUseOnlyThisAccountsLiveMeetingsAndPendingChanges() {
        val extra = AccountProject(UUID.randomUUID(), "Pending account project")
        val removed = AccountProject(UUID.randomUUID(), "Deleted meeting project")
        val catalog = accountProjects(listOf(meeting(project), meeting(project), meeting(removed).put("deleted", true)),
            listOf(meeting(extra)))
        assertEquals(setOf(project, extra), catalog.toSet())
        assertTrue(accountProjects(emptyList(), emptyList()).isEmpty())
    }
}
