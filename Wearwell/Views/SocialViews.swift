import SwiftData
import SwiftUI

struct FriendsView: View {
    @EnvironmentObject private var hosted: HostedClient
    @Environment(\.modelContext) private var context
    @State private var profileName = ""
    @State private var friends: [SocialFriendDTO] = []
    @State private var shares: [SharedOutfitSummaryDTO] = []
    @State private var activity: [SocialActivityDTO] = []
    @State private var invite: FriendInviteDTO?
    @State private var working = false
    @State private var message: String?
    @State private var error: String?

    var body: some View {
        List {
            Section("Your profile") {
                TextField("Display name", text: $profileName)
                    .textInputAutocapitalization(.words)
                Button("Save display name") { Task { await saveProfile() } }
                    .disabled(working || profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let token = hosted.pendingFriendInviteToken {
                Section("Friend invitation") {
                    Text("Accept this private Wearwell friend invitation?")
                    Button("Accept invitation") { Task { await redeem(token) } }
                        .disabled(working)
                    Button("Not now", role: .cancel) { hosted.pendingFriendInviteToken = nil }
                }
            }

            Section("Invite a friend") {
                Text("Links expire after seven days and can be used once.")
                    .font(.caption).foregroundStyle(.secondary)
                if let invite, let url = URL(string: invite.url) {
                    ShareLink(item: url, subject: Text("Join me on Wearwell"), message: Text("Accept my private Wearwell friend invitation.")) {
                        Label("Send invitation", systemImage: "square.and.arrow.up")
                    }
                    Text("Expires: \(invite.expiresAt)").font(.caption2).foregroundStyle(.secondary)
                } else {
                    Button("Create invitation link") { Task { await createInvite() } }.disabled(working)
                }
            }

            Section("Friends") {
                if friends.isEmpty {
                    Text("No friends yet. Send a private invitation link to someone you trust.")
                        .foregroundStyle(.secondary)
                }
                ForEach(friends) { friend in
                    HStack {
                        Image(systemName: "person.crop.circle.fill").foregroundStyle(WearwellTheme.sage)
                        Text(friend.displayName)
                        Spacer()
                        Menu {
                            Button("Remove friend", role: .destructive) { Task { await remove(friend) } }
                            Button("Block", role: .destructive) { Task { await block(friend) } }
                        } label: { Image(systemName: "ellipsis") }
                    }
                }
            }

            Section("Shared with you") {
                if shares.isEmpty { Text("Private outfit shares will appear here.").foregroundStyle(.secondary) }
                ForEach(shares) { share in
                    NavigationLink {
                        SharedOutfitDetailView(shareID: share.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(share.snapshot.title).font(.headline)
                            Text("From \(share.displayName ?? "a friend")").font(.caption).foregroundStyle(.secondary)
                            HStack {
                                if share.reacted { Label("Loved", systemImage: "heart.fill") }
                                if share.copied { Label("Saved", systemImage: "square.and.arrow.down.fill") }
                            }.font(.caption2).foregroundStyle(WearwellTheme.coral)
                        }
                    }
                }
            }

            Section("Activity") {
                if activity.isEmpty { Text("Friend and share activity will appear here.").foregroundStyle(.secondary) }
                ForEach(activity) { event in
                    HStack(alignment: .top) {
                        Circle().fill(event.readAt == nil ? WearwellTheme.coral : Color.clear).frame(width: 7,height: 7).padding(.top,6)
                        Text(activityText(event)).font(.subheadline)
                    }
                }
            }

            if let message { Section { Text(message).foregroundStyle(WearwellTheme.sage) } }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle("Friends")
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        guard hosted.status == .available else { return }
        working = true; defer { working = false }
        do {
            async let profileValue = hosted.socialProfile()
            async let friendValues = hosted.friends()
            async let shareValues = hosted.sharedOutfits()
            async let activityValues = hosted.activity()
            let values = try await (profileValue,friendValues,shareValues,activityValues)
            profileName = values.0.displayName; friends = values.1; shares = values.2; activity = values.3
            if let first = activity.first, activity.contains(where: { $0.readAt == nil }) {
                try? await hosted.markActivityRead(through: first.id)
            }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func saveProfile() async {
        working = true; defer { working = false }
        do { profileName = try await hosted.updateSocialProfile(displayName: profileName).displayName; message = "Profile saved."; error = nil }
        catch { self.error = error.localizedDescription }
    }

    private func createInvite() async {
        working = true; defer { working = false }
        do { invite = try await hosted.createFriendInvite(); error = nil }
        catch { self.error = error.localizedDescription }
    }

    private func redeem(_ token: String) async {
        working = true; defer { working = false }
        do { let friend = try await hosted.redeemFriendInvite(token); message = "You and \(friend.displayName) are now friends."; await load() }
        catch { self.error = error.localizedDescription }
    }

    private func remove(_ friend: SocialFriendDTO) async {
        do { try await hosted.removeFriend(friend.id); await load() }
        catch { self.error = error.localizedDescription }
    }

    private func block(_ friend: SocialFriendDTO) async {
        do { try await hosted.blockMember(friend.id); await load() }
        catch { self.error = error.localizedDescription }
    }

    private func activityText(_ event: SocialActivityDTO) -> String {
        switch event.kind {
        case "friend_accepted": "\(event.actorName) accepted your friend invitation."
        case "share_received": "\(event.actorName) shared an outfit with you."
        case "reaction_received": "\(event.actorName) loved your shared outfit."
        default: "New activity from \(event.actorName)."
        }
    }
}

struct ShareOutfitView: View {
    let outfit: Outfit
    let preview: Data
    @EnvironmentObject private var hosted: HostedClient
    @Environment(\.dismiss) private var dismiss
    @State private var friends: [SocialFriendDTO] = []
    @State private var selectedFriendID: String?
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Exactly what will be shared") {
                    if let image = UIImage(data: preview) { Image(uiImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 16)) }
                    Text(outfit.title).font(.headline)
                    if !outfit.rationale.isEmpty { Text(outfit.rationale).font(.caption).foregroundStyle(.secondary) }
                    Text("Your wardrobe records and original garment photos stay private.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Choose one friend") {
                    if friends.isEmpty { Text("Add a friend in Settings before sharing.").foregroundStyle(.secondary) }
                    ForEach(friends) { friend in
                        Button {
                            selectedFriendID = friend.id
                        } label: {
                            HStack { Text(friend.displayName); Spacer(); if selectedFriendID == friend.id { Image(systemName: "checkmark.circle.fill") } }
                        }
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("Share privately")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(working ? "Sharing…" : "Share") { Task { await share() } }.disabled(working || selectedFriendID == nil) }
            }
            .task {
                do { friends = try await hosted.friends(); selectedFriendID = friends.first?.id }
                catch { self.error = error.localizedDescription }
            }
        }
    }

    private func share() async {
        guard let selectedFriendID else { return }
        working = true; defer { working = false }
        do { _ = try await hosted.shareOutfit(id: outfit.id,title: outfit.title,rationale: outfit.rationale,preview: preview,with:selectedFriendID); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}

struct SharedOutfitDetailView: View {
    let shareID: String
    @EnvironmentObject private var hosted: HostedClient
    @Environment(\.modelContext) private var context
    @State private var share: SharedOutfitDetailDTO?
    @State private var working = false
    @State private var message: String?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let share {
                    AsyncImage(url: URL(string: share.previewURL)) { image in image.resizable().scaledToFit() } placeholder: { ProgressView().frame(maxWidth:.infinity,minHeight:300) }
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                    Text(share.snapshot.title).font(.largeTitle.bold())
                    Text("Shared by \(share.displayName ?? "a friend")").foregroundStyle(.secondary)
                    if !share.snapshot.rationale.isEmpty { Text(share.snapshot.rationale) }
                    HStack {
                        Button { Task { await toggleHeart() } } label: { Label(share.reacted ? "Loved" : "Love",systemImage:share.reacted ? "heart.fill" : "heart") }.buttonStyle(.bordered)
                        Button { Task { await copy() } } label: { Label(share.copied ? "Saved" : "Copy to Inspiration",systemImage:"square.and.arrow.down") }.buttonStyle(.borderedProminent).disabled(share.copied || working)
                    }
                } else if let error { ContentUnavailableView("Share unavailable",systemImage:"lock",description:Text(error)) }
                else { ProgressView().frame(maxWidth:.infinity,minHeight:300) }
                if let message { Text(message).foregroundStyle(WearwellTheme.sage) }
            }.padding()
        }.background(WearwellTheme.cream).navigationTitle("Shared outfit").task { await load() }
    }

    private func load() async { do { share = try await hosted.sharedOutfit(shareID); error = nil } catch { self.error = error.localizedDescription } }
    private func toggleHeart() async {
        guard var value = share else { return }
        do { try await hosted.setHeart(!value.reacted,shareID:shareID); value.reacted.toggle(); share = value }
        catch { self.error = error.localizedDescription }
    }
    private func copy() async {
        working = true; defer { working = false }
        do { _ = try await hosted.copyShareToInspiration(shareID); try await hosted.synchronizeCache(context:context,force:true); share?.copied = true; message = "Copied to your private Inspiration library." }
        catch { self.error = error.localizedDescription }
    }
}
