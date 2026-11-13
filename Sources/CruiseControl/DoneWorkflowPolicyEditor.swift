import SwiftUI
import CruiseCore

/// Shared policy editor used by both HeyClicky and VS Code task details.
struct DoneWorkflowPolicyEditor: View {
    @Binding var plan: TaskPlan
    let confirmedWorkspace: Bool
    let branches: [String]
    @Binding var newBranchName: String
    let branchStatus: String?
    let onCreateBranch: () -> Void
    var requiresBuildLocation = true
    var workspace: String? = nil
    @State private var expanded = false
    @State private var choosingBuildFolder = false

    private var missing: String? {
        confirmedWorkspace ? TaskWorkflow.autoBumpBlocker(plan: plan, requiresBuildLocation: requiresBuildLocation, workspace: workspace) : "Confirm a project folder before drafting or sending."
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 7) {
                if let missing {
                    Label(missing, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                if confirmedWorkspace && requiresBuildLocation {
                    Picker("Build location", selection: $plan.buildLocation) {
                        Text("Choose later").tag(TaskBuildLocation?.none)
                        ForEach(TaskBuildLocation.allCases) { choice in
                            Text(choice.title).tag(Optional(choice))
                        }
                    }
                    if plan.buildLocation == .externalFolder {
                        Button("Choose external build folder…") { choosingBuildFolder = true }
                        if let path = plan.externalBuildDirectory {
                            Text(path).textSelection(.enabled)
                        }
                    }
                } else if confirmedWorkspace {
                    Text("Build in the confirmed VS Code agent workspace. Cruise does not create or assume an agent cache.")
                        .foregroundStyle(.secondary)
                }
                if !confirmedWorkspace {
                    Label("Confirm a project folder to configure repository policies.", systemImage: "folder.badge.questionmark")
                        .foregroundStyle(.secondary)
                } else if let workspace, TaskWorkspaceGit.isPlainFolder(workspace) {
                    Text("Local folder workflow. No GitHub account, repository, branch or Git delivery choices are required.")
                    Button("Set up Git / GitHub in Terminal…") {
                        GitHubWorkspaceSetup.open(workspace: workspace)
                    }
                    Text("Optional: initializes local Git and opens GitHub CLI browser authentication in Terminal. You complete login and 2FA yourself. No remote repository is created or files committed automatically.")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Picker("When Done", selection: $plan.deliveryStyle) {
                        Text("Choose later").tag(TaskDeliveryStyle?.none)
                        Text("Commit / push to selected branch").tag(TaskDeliveryStyle?.some(.commit))
                        Text("Submit a pull request").tag(TaskDeliveryStyle?.some(.pullRequest))
                    }
                    Picker("Branch organization", selection: $plan.branchStrategy) {
                        Text("Choose later").tag(TaskBranchStrategy?.none)
                        ForEach(TaskBranchStrategy.allCases) { choice in
                            Text(choice.title).tag(Optional(choice))
                        }
                    }
                    if plan.branchStrategy != nil {
                        Picker("Selected work branch", selection: $plan.workBranch) {
                            Text("Choose a branch").tag("")
                            ForEach(branches, id: \.self) { branch in Text(branch).tag(branch) }
                        }
                        HStack(spacing: 6) {
                            TextField("Create local branch name", text: $newBranchName)
                                .textFieldStyle(.roundedBorder)
                            Button("Create & select") { onCreateBranch() }
                                .buttonStyle(ClickyPillButtonStyle(primary: false))
                                .disabled(newBranchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        Text("Create & select adds a local branch and selects it for these instructions; it does not switch the repository's checked-out branch or change files.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Toggle("Mark as Finished requests a pending-work commit", isOn: $plan.commitPendingOnFinish)
                        .disabled(plan.workBranch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Picker("When Mark as Finished", selection: $plan.finishMergeTarget) {
                        Text("Choose later").tag(TaskMergeTarget?.none)
                        ForEach(TaskMergeTarget.allCases) { choice in
                            Text(choice.title).tag(Optional(choice))
                        }
                    }
                    if let branchStatus {
                        Text(branchStatus).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Text("These choices are sent with the first and later messages. Cruise passes instructions to the agent; it does not itself build, commit, push, create PRs, or merge.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .padding(.leading, 8)
            .padding(.top, 6)
        } label: {
            Label("Build, branches & finishing", systemImage: missing == nil ? "checkmark.circle" : "exclamationmark.triangle.fill")
                .foregroundStyle(missing == nil ? Color.primary : Color.orange)
        }
        .onAppear { if missing != nil { expanded = true } }
        .onChange(of: missing) { _, value in if value != nil { expanded = true } }
        .fileImporter(isPresented: $choosingBuildFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url):
                plan.externalBuildDirectory = url.standardizedFileURL.path
            case .failure(let error):
                NSAlert(error: error).runModal()
            }
        }
        .accessibilityIdentifier("done-workflow-policies")
    }
}
