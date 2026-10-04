//
//  PresenceVisibility.swift
//  PetCore
//

public nonisolated enum PresenceVisibility {
    /// Whether the Mac shows the friend: only while its user is active and no iPhone nearby has claimed it; then
    /// when the backend says the Mac owns it, or when the backend can't be reached (the friend shouldn't vanish
    /// just because the network did).
    public static func macShowsFriend(isActive: Bool, owner: PresenceOwner?, socketConnected: Bool, phoneClaimedNearby: Bool) -> Bool {
        guard isActive, !phoneClaimedNearby else { return false }
        return owner == .mac || !socketConnected
    }

    /// Whether the friend is out: where presence puts it, unless the user sent it home (until they let it out or a
    /// focus ends) or a focus keeps it home (after its goodbye line). Sent home, nothing else brings it out: not
    /// coming back from idle, waking, unlocking, the iPhone letting go or the network dropping.
    public static func friendShows(presenceShows: Bool, focusHome: Bool, inGoodbye: Bool, sentHome: Bool) -> Bool {
        presenceShows && !sentHome && !(focusHome && !inGoodbye)
    }
}
