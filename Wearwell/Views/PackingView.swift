import SwiftData
import SwiftUI

struct PackingTripsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \PackingTrip.startDate, order: .reverse) private var trips: [PackingTrip]
    @State private var creatingTrip = false

    var body: some View {
        ZStack {
            WearwellTheme.cream.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 18) {
                    EditorialHeader(
                        eyebrow: "Plan what comes with you",
                        title: "Packing",
                        subtitle: "Choose outfits for each day and Wearwell will build your packing checklist."
                    )
                    Button { creatingTrip = true } label: {
                        Label("New trip", systemImage: "plus")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)

                    if trips.isEmpty {
                        EmptyState(icon: "suitcase", title: "No trips yet", message: "Create a trip to start planning outfits by day.")
                            .frame(minHeight: 300)
                    } else {
                        ForEach(trips) { trip in
                            NavigationLink { PackingTripDetailView(trip: trip) } label: {
                                PackingTripCard(trip: trip)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding()
            }
        }
        .navigationTitle("Packing")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $creatingTrip) { CreatePackingTripView() }
    }
}

private struct PackingTripCard: View {
    let trip: PackingTrip

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "suitcase.rolling")
                .font(.title2)
                .foregroundStyle(WearwellTheme.coral)
                .frame(width: 52, height: 52)
                .background(WearwellTheme.coral.opacity(0.12), in: RoundedRectangle(cornerRadius: 15))
            VStack(alignment: .leading, spacing: 4) {
                Text(trip.title).font(.headline).foregroundStyle(WearwellTheme.ink)
                Text(tripDateRange(trip.startDate, trip.endDate))
                    .font(.subheadline).foregroundStyle(WearwellTheme.muted)
                Text("\(trip.assignments.count) outfit\(trip.assignments.count == 1 ? "" : "s") planned")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .padding()
        .background(WearwellTheme.paper, in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct CreatePackingTripView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var title = ""
    @State private var startDate = Calendar.current.startOfDay(for: .now)
    @State private var endDate = Calendar.current.date(byAdding: .day, value: 2, to: Calendar.current.startOfDay(for: .now)) ?? .now

    var body: some View {
        NavigationStack {
            Form {
                TextField("Trip name", text: $title)
                DatePicker("Starts", selection: $startDate, displayedComponents: .date)
                DatePicker("Ends", selection: $endDate, in: startDate..., displayedComponents: .date)
            }
            .navigationTitle("New trip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        context.insert(PackingTrip(title: name, startDate: startDate, endDate: endDate))
                        try? context.save()
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onChange(of: startDate) { _, value in if endDate < value { endDate = value } }
        }
        .keyboardDismissToolbar()
    }
}

struct PackingTripDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Bindable var trip: PackingTrip
    @Query(sort: \Outfit.updatedAt, order: .reverse) private var outfits: [Outfit]
    @Query private var garments: [Garment]
    @State private var mode = "plan"
    @State private var selectedDay: SelectedPackingDay?
    @State private var editingTrip = false
    @State private var confirmingDelete = false

    private var savedOutfits: [Outfit] { outfits.filter(\.belongsInOutfitLibrary) }
    private var requiredGarments: [Garment] {
        PackingListBuilder.requiredGarments(assignments: trip.assignments, outfits: outfits, garments: garments)
    }
    private var requiredIDs: Set<UUID> { Set(requiredGarments.map(\.id)) }

    var body: some View {
        ZStack {
            WearwellTheme.cream.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 18) {
                    EditorialHeader(eyebrow: tripDateRange(trip.startDate, trip.endDate), title: trip.title, subtitle: "Plan each day, then check off every piece as it goes in your bag.")
                    Picker("Packing view", selection: $mode) {
                        Label("Plan", systemImage: "calendar").tag("plan")
                        Label("Pack", systemImage: "checklist").tag("pack")
                    }
                    .pickerStyle(.segmented)

                    if mode == "plan" { planView } else { packView }
                }
                .padding()
            }
        }
        .navigationTitle(trip.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Edit trip", systemImage: "pencil") { editingTrip = true }
                    Button("Delete trip", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .sheet(item: $selectedDay) { selection in
            PackingOutfitPicker(trip: trip, day: selection.day, outfits: savedOutfits, garments: garments)
        }
        .sheet(isPresented: $editingTrip) { EditPackingTripView(trip: trip, outfits: outfits) }
        .confirmationDialog("Delete \(trip.title)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete trip", role: .destructive) {
                context.delete(trip)
                try? context.save()
                dismiss()
            }
        }
        .onAppear { reconcilePackedState() }
        .onChange(of: requiredIDs) { _, _ in reconcilePackedState() }
    }

    private var planView: some View {
        VStack(spacing: 14) {
            ForEach(trip.days(), id: \.self) { day in
                let assignments = assignments(on: day)
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(day, format: .dateTime.weekday(.wide)).font(.headline)
                            Text(day, format: .dateTime.month(.abbreviated).day()).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { selectedDay = SelectedPackingDay(day: day) } label: { Label("Add outfit", systemImage: "plus") }
                            .buttonStyle(.bordered)
                    }
                    if assignments.isEmpty {
                        Text("No outfits planned").font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 8)
                    } else {
                        ForEach(assignments) { assignment in
                            if let outfit = outfits.first(where: { $0.id == assignment.outfitID }) {
                                HStack(spacing: 12) {
                                    CollagePreview(items: outfit.layout, garments: garments, candidate: nil)
                                        .frame(width: 72, height: 82)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(outfit.title).font(.headline)
                                        Text("\(outfit.layout.compactMap(\.garmentID).count) pieces").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button(role: .destructive) { remove(assignment) } label: { Image(systemName: "minus.circle") }
                                        .accessibilityLabel("Remove \(outfit.title)")
                                }
                            } else {
                                HStack {
                                    Label("Outfit unavailable", systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                                    Spacer()
                                    Button(role: .destructive) { remove(assignment) } label: { Image(systemName: "trash") }
                                        .accessibilityLabel("Remove unavailable outfit")
                                }
                            }
                        }
                    }
                }
                .padding()
                .background(WearwellTheme.paper, in: RoundedRectangle(cornerRadius: 18))
            }
        }
    }

    @ViewBuilder private var packView: some View {
        if requiredGarments.isEmpty {
            EmptyState(icon: "checklist", title: "Your list is empty", message: "Add an outfit to a day and its wardrobe pieces will appear here.")
                .frame(minHeight: 300)
        } else {
            VStack(spacing: 16) {
                let packedCount = requiredIDs.intersection(trip.packedGarmentIDs).count
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text("\(packedCount) of \(requiredGarments.count) packed").font(.headline); Spacer(); Text("\(Int(Double(packedCount) / Double(requiredGarments.count) * 100))%").foregroundStyle(.secondary) }
                    ProgressView(value: Double(packedCount), total: Double(requiredGarments.count)).tint(WearwellTheme.sage)
                }
                .padding()
                .background(WearwellTheme.paper, in: RoundedRectangle(cornerRadius: 18))

                ForEach(GarmentCategory.allCases) { category in
                    let categoryGarments = requiredGarments.filter { $0.category == category }
                    if !categoryGarments.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(category.title).font(.title3.bold()).padding(.bottom, 4)
                            ForEach(categoryGarments) { garment in
                                Button { togglePacked(garment.id) } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: trip.packedGarmentIDs.contains(garment.id) ? "checkmark.circle.fill" : "circle")
                                            .font(.title3).foregroundStyle(WearwellTheme.sage)
                                        CollageAssetImage(name: garment.catalogAssetName.isEmpty ? garment.sourceAssetName : garment.catalogAssetName)
                                            .frame(width: 46, height: 52)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(garment.label).font(.headline).foregroundStyle(WearwellTheme.ink)
                                            Text(garment.color).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                    }
                                    .padding(.vertical, 7)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(garment.label), \(trip.packedGarmentIDs.contains(garment.id) ? "packed" : "not packed")")
                            }
                        }
                        .padding()
                        .background(WearwellTheme.paper, in: RoundedRectangle(cornerRadius: 18))
                    }
                }
            }
        }
    }

    private func assignments(on day: Date) -> [PackingAssignment] {
        trip.assignments.filter { Calendar.current.isDate($0.day, inSameDayAs: day) }
    }

    private func remove(_ assignment: PackingAssignment) {
        trip.removeAssignment(id: assignment.id)
        reconcilePackedState()
        try? context.save()
    }

    private func togglePacked(_ garmentID: UUID) {
        trip.setPacked(!trip.packedGarmentIDs.contains(garmentID), garmentID: garmentID)
        try? context.save()
    }

    private func reconcilePackedState() {
        trip.reconcilePackedGarments(requiredIDs: requiredIDs)
        try? context.save()
    }
}

private struct PackingOutfitPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Bindable var trip: PackingTrip
    let day: Date
    let outfits: [Outfit]
    let garments: [Garment]

    var body: some View {
        NavigationStack {
            Group {
                if outfits.isEmpty {
                    EmptyState(icon: "sparkles.rectangle.stack", title: "No saved outfits", message: "Create and save an outfit in Studio first.")
                } else {
                    List(outfits) { outfit in
                        Button { toggle(outfit) } label: {
                            HStack(spacing: 12) {
                                CollagePreview(items: outfit.layout, garments: garments, candidate: nil).frame(width: 64, height: 74)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(outfit.title).font(.headline).foregroundStyle(.primary)
                                    Text("\(outfit.layout.compactMap(\.garmentID).count) pieces").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: isAssigned(outfit) ? "checkmark.circle.fill" : "circle").font(.title3).foregroundStyle(WearwellTheme.sage)
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .background(WearwellTheme.cream)
                }
            }
            .navigationTitle(day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func isAssigned(_ outfit: Outfit) -> Bool {
        trip.assignments.contains { Calendar.current.isDate($0.day, inSameDayAs: day) && $0.outfitID == outfit.id }
    }

    private func toggle(_ outfit: Outfit) {
        if let assignment = trip.assignments.first(where: { Calendar.current.isDate($0.day, inSameDayAs: day) && $0.outfitID == outfit.id }) {
            trip.removeAssignment(id: assignment.id)
        } else {
            trip.addAssignment(day: day, outfitID: outfit.id)
        }
        let required = PackingListBuilder.requiredGarmentIDs(assignments: trip.assignments, outfits: outfits)
        trip.reconcilePackedGarments(requiredIDs: required)
        try? context.save()
    }
}

private struct EditPackingTripView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    let trip: PackingTrip
    let outfits: [Outfit]
    @State private var title: String
    @State private var startDate: Date
    @State private var endDate: Date

    init(trip: PackingTrip, outfits: [Outfit]) {
        self.trip = trip
        self.outfits = outfits
        _title = State(initialValue: trip.title)
        _startDate = State(initialValue: trip.startDate)
        _endDate = State(initialValue: trip.endDate)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Trip name", text: $title)
                DatePicker("Starts", selection: $startDate, displayedComponents: .date)
                DatePicker("Ends", selection: $endDate, in: startDate..., displayedComponents: .date)
            }
            .navigationTitle("Edit trip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }
            .onChange(of: startDate) { _, value in if endDate < value { endDate = value } }
        }
        .keyboardDismissToolbar()
    }

    private func save() {
        let calendar = Calendar.current
        let first = calendar.startOfDay(for: startDate)
        let last = max(calendar.startOfDay(for: endDate), first)
        trip.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        trip.startDate = first
        trip.endDate = last
        trip.assignments = trip.assignments.filter { $0.day >= first && $0.day <= last }
        trip.reconcilePackedGarments(requiredIDs: PackingListBuilder.requiredGarmentIDs(assignments: trip.assignments, outfits: outfits))
        trip.updatedAt = .now
        try? context.save()
        dismiss()
    }
}

private struct SelectedPackingDay: Identifiable {
    let day: Date
    var id: Date { day }
}

private func tripDateRange(_ start: Date, _ end: Date) -> String {
    if Calendar.current.isDate(start, inSameDayAs: end) {
        return start.formatted(.dateTime.month(.abbreviated).day().year())
    }
    return "\(start.formatted(.dateTime.month(.abbreviated).day())) – \(end.formatted(.dateTime.month(.abbreviated).day().year()))"
}
