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
}
