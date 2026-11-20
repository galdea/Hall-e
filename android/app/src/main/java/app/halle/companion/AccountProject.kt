package app.halle.companion

import org.json.JSONObject
import java.util.UUID

/** A project in one Hall-e account. A device calendar or local project name is never an ID. */
internal data class AccountProject(val id: UUID, val name: String) {
    init {
        require(name.isNotBlank() && name.length <= 120 && name.none { it.code < 32 || it.code == 127 })
    }
    fun json(): JSONObject = JSONObject().put("id", id.toString()).put("name", name)

    companion object {
        fun read(value: JSONObject?): AccountProject? {
            if (value == null) return null
            return runCatching {
                val raw = value.getString("id")
                val uuid = UUID.fromString(raw)
                require(uuid.toString().equals(raw, ignoreCase = true))
                AccountProject(uuid, value.getString("name"))
            }.getOrNull()
        }
    }
}

internal data class ProjectChange(val project: AccountProject?)

internal fun stageProject(change: JSONObject, edit: ProjectChange?, previous: AccountProject?) {
    if (edit != null) change.put("project", edit.project?.json() ?: JSONObject.NULL)
    else change.put("projectAtEdit", previous?.json() ?: JSONObject.NULL)
}

// Keep the original project available for conflict recovery without implicitly changing the server assignment.
internal fun meetingRequest(change: JSONObject): JSONObject {
    val request = JSONObject()
    for (field in listOf("title", "startAt", "endAt", "deleted", "baseRevision", "mutationId", "project")) {
        if (change.has(field)) request.put(field, change.get(field))
    }
    return request
}

internal fun pendingProject(change: JSONObject, current: JSONObject?): AccountProject? {
    val value = when {
        change.has("project") -> change.optJSONObject("project")
        change.has("projectAtEdit") -> change.optJSONObject("projectAtEdit")
        else -> current?.optJSONObject("project")
    }
    return AccountProject.read(value)
}

internal fun projectSelectionAccepted(change: JSONObject, accepted: JSONObject): Boolean =
    !change.has("project") || AccountProject.read(change.optJSONObject("project"))?.id ==
        AccountProject.read(accepted.optJSONObject("project"))?.id

internal fun accountProjects(snapshot: List<JSONObject>, pending: List<JSONObject>): List<AccountProject> {
    val fromAccount = snapshot.filterNot { it.optBoolean("deleted") }.mapNotNull { AccountProject.read(it.optJSONObject("project")) }
    val fromPhone = pending.filterNot { it.optBoolean("deleted") }.mapNotNull { pendingProject(it, null) }
    return (fromAccount + fromPhone).distinctBy { it.id }.sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER) { it.name })
}
