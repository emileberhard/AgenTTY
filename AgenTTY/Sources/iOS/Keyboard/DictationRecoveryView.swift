import DictationLibrary
import SwiftUI

@MainActor
struct DictationRecoveryView: View {
    let library: AgenTTYDictationLibrary
    @State private var snapshot: AgenTTYDictationLibrary.RecoverySnapshot?
    private struct Assignment {
        let captureID: UUID
        let account: DictationAccountSession
    }

    @State private var selection: Assignment?
    @State private var confirmationPresented = false
    @State private var releaseConfirmationPresented = false
    @State private var releaseAccount: DictationAccountSession?
    @State private var releaseCutoff: Date?
    @State private var completionMessage: String?
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
            if let completionMessage {
                Text(completionMessage).foregroundStyle(.secondary)
            }
            if let snapshot {
                if let notice = snapshot.notice {
                    Text(notice).foregroundStyle(.secondary)
                }
                if let failure = snapshot.publication.failures.first {
                    Section("Recordings Needing Attention") {
                        LabeledContent("Failed", value: String(snapshot.publication.failures.count))
                        Text(failure.message).foregroundStyle(.red)
                    }
                }
                Section("Local Storage") {
                    LabeledContent("Used", value: ByteCountFormatter.string(fromByteCount: snapshot.publication.usedBytes, countStyle: .file))
                    LabeledContent("Uploaded Audio", value: ByteCountFormatter.string(fromByteCount: snapshot.publication.releasableBytes, countStyle: .file))
                    Button("Free Uploaded Local Audio", role: .destructive) {
                        releaseAccount = snapshot.account
                        releaseCutoff = .now
                        releaseConfirmationPresented = true
                    }
                    .disabled(snapshot.account == nil || snapshot.publication.releasableBytes == 0 || isWorking)
                }
                Section("Unverified Recordings") {
                    if snapshot.captures.isEmpty {
                        Text("No recordings need assignment.").foregroundStyle(.secondary)
                    }
                    ForEach(snapshot.captures) { capture in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(capture.capture.startedAt, format: .dateTime.day().month().year().hour().minute())
                            if let original = capture.originalURL {
                                ShareLink(item: original) {
                                    Label("Export Original", systemImage: "square.and.arrow.up")
                                }
                            } else {
                                Text("Original audio needs recovery.").foregroundStyle(.secondary)
                            }
                            Button("Assign to Current iCloud Account") {
                                guard let account = snapshot.account else { return }
                                selection = Assignment(captureID: capture.id, account: account)
                                confirmationPresented = true
                            }
                            .disabled(!snapshot.canAdopt || isWorking)
                        }
                        .padding(.vertical, 4)
                    }
                }
                if !snapshot.canAdopt && !snapshot.captures.isEmpty {
                    Text("Confirm your iCloud account and enable archiving in AgenTTY and WisprClone to assign recordings.")
                        .foregroundStyle(.secondary)
                }
                if snapshot.otherAccountCount > 0 {
                    Section("Other iCloud Accounts") {
                        Text("\(snapshot.otherAccountCount) recording(s) remain with another account. Sign back into that account to sync them.")
                    }
                }
            } else if isWorking {
                ProgressView()
            }
        }
        .navigationTitle("Recording Recovery")
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") {
                Task { await reload() }
            }
            .disabled(isWorking)
        }
        .task { await reload() }
        .alert("Free uploaded local audio?", isPresented: $releaseConfirmationPresented) {
            Button("Free Local Audio", role: .destructive) {
                guard let releaseAccount, let releaseCutoff else { return }
                Task {
                    isWorking = true
                    do {
                        let report = try await library.freeUploadedLocalAudio(account: releaseAccount, cutoff: releaseCutoff)
                        completionMessage = "Freed " + ByteCountFormatter.string(fromByteCount: report.releasedBytes, countStyle: .file) + "."
                    } catch { errorMessage = error.localizedDescription }
                    isWorking = false
                    await reload(clearError: false)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes this device’s copies of originals fully uploaded to iCloud. Pending and unverified recordings stay here. iCloud copies remain; a separate backup is not verified here.")
        }
        .confirmationDialog("Assign this recording to your current iCloud account?", isPresented: $confirmationPresented, titleVisibility: .visible) {
            Button("Assign and Sync") {
                guard let selection else { return }
                Task {
                    isWorking = true
                    do { try await library.adoptHeldCapture(id: selection.captureID, account: selection.account) }
                    catch { errorMessage = error.localizedDescription }
                    isWorking = false
                    await reload(clearError: false)
                }
            }
        } message: {
            Text("The original and its saved results will be added to that account’s private dictation library.")
        }
    }

    private func reload(clearError: Bool = true) async {
        isWorking = true
        if clearError { errorMessage = nil }
        snapshot = nil
        do { snapshot = try await library.recoverySnapshot() }
        catch { errorMessage = error.localizedDescription }
        isWorking = false
    }
}
