import SwiftUI

struct CabinetDepartment: Identifiable {
    let id: String
    let name: String
    let icon: String

    static let allDepartments: [CabinetDepartment] = [
        CabinetDepartment(id: "state", name: "Department of State", icon: "globe"),
        CabinetDepartment(id: "treasury", name: "Department of the Treasury", icon: "dollarsign.circle"),
        CabinetDepartment(id: "defense", name: "Department of Defense", icon: "shield"),
        CabinetDepartment(id: "justice", name: "Department of Justice", icon: "scalemass"),
        CabinetDepartment(id: "interior", name: "Department of the Interior", icon: "mountain.2"),
        CabinetDepartment(id: "agriculture", name: "Department of Agriculture", icon: "leaf"),
        CabinetDepartment(id: "commerce", name: "Department of Commerce", icon: "chart.bar"),
        CabinetDepartment(id: "labor", name: "Department of Labor", icon: "hammer"),
        CabinetDepartment(id: "hhs", name: "Department of Health and Human Services", icon: "heart"),
        CabinetDepartment(id: "hud", name: "Department of Housing and Urban Development", icon: "house"),
        CabinetDepartment(id: "transportation", name: "Department of Transportation", icon: "car"),
        CabinetDepartment(id: "energy", name: "Department of Energy", icon: "bolt"),
        CabinetDepartment(id: "education", name: "Department of Education", icon: "book"),
        CabinetDepartment(id: "veterans", name: "Department of Veterans Affairs", icon: "flag"),
        CabinetDepartment(id: "dhs", name: "Department of Homeland Security", icon: "lock.shield"),
        // Major independent agencies
        CabinetDepartment(id: "epa", name: "Environmental Protection Agency", icon: "tree"),
        CabinetDepartment(id: "nasa", name: "NASA", icon: "airplane"),



        CabinetDepartment(id: "fda", name: "Food and Drug Administration", icon: "pills"),
        CabinetDepartment(id: "fcc", name: "Federal Communications Commission", icon: "antenna.radiowaves.left.and.right"),
        CabinetDepartment(id: "sec", name: "Securities and Exchange Commission", icon: "chart.line.uptrend.xyaxis"),
        CabinetDepartment(id: "ftc", name: "Federal Trade Commission", icon: "cart"),
        CabinetDepartment(id: "fema", name: "Federal Emergency Management Agency", icon: "exclamationmark.triangle"),
        CabinetDepartment(id: "sba", name: "Small Business Administration", icon: "storefront"),
        CabinetDepartment(id: "omb", name: "Office of Management and Budget", icon: "doc.text"),

        CabinetDepartment(id: "ustr", name: "Office of the U.S. Trade Representative", icon: "arrow.left.arrow.right"),
        CabinetDepartment(id: "usps", name: "United States Postal Service", icon: "envelope"),
        CabinetDepartment(id: "ssa", name: "Social Security Administration", icon: "person.2"),
        CabinetDepartment(id: "va", name: "Veterans Administration", icon: "cross"),
        CabinetDepartment(id: "doge", name: "Department of Government Efficiency", icon: "gearshape.2"),
    ]
}

struct NewDepartmentView: View {
    @Environment(\.dismiss) private var dismiss
    let onCreate: (_ chatId: String, _ name: String) -> Void

    @State private var searchText = ""
    @State private var customId = ""
    @State private var customName = ""
    @State private var showCustomInput = false

    private var filteredDepartments: [CabinetDepartment] {
        if searchText.isEmpty {
            return CabinetDepartment.allDepartments
        }
        return CabinetDepartment.allDepartments.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.id.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if showCustomInput {
                    Section("Custom Department") {
                        TextField("Department ID (e.g. science)", text: $customId)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        TextField("Display Name", text: $customName)
                        Button("Establish") {
                            let chatId = customId.trimmingCharacters(in: .whitespacesAndNewlines)
                            let name = customName.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !chatId.isEmpty else { return }
                            onCreate(chatId, name.isEmpty ? chatId : name)
                            dismiss()
                        }
                        .disabled(customId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                Section(showCustomInput ? "Or Choose from Cabinet" : "Cabinet Departments") {
                    ForEach(filteredDepartments) { dept in
                        Button {
                            onCreate(dept.id, dept.name)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: dept.icon)
                                    .foregroundStyle(.blue)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(dept.name)
                                        .foregroundStyle(.primary)
                                    Text(dept.id)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    if filteredDepartments.isEmpty && !searchText.isEmpty {
                        Text("No matching departments")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search departments")
            .navigationTitle("New Department")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showCustomInput.toggle()
                    } label: {
                        Image(systemName: showCustomInput ? "list.bullet" : "pencil")
                    }
                }
            }
        }
    }
}
