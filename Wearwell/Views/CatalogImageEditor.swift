import SwiftUI
import UIKit

struct CatalogImageEditor: View {
    @Binding private var imageData: Data?
    let sourceData: Data

    @EnvironmentObject private var hosted: HostedClient
    @Environment(\.dismiss) private var dismiss
    @State private var workingData: Data
    @State private var originalData: Data
    @State private var strokes: [[CGPoint]] = []
    @State private var activeStroke: [CGPoint] = []
    @State private var brushFraction: Double = 0.07
    @State private var instruction = ""
    @State private var applyingEdit = false
    @State private var editJob: CatalogEditJobDTO?
    @State private var error: String?

    init(imageData: Binding<Data?>, sourceData: Data) {
        _imageData = imageData
        self.sourceData = sourceData
        let initial = imageData.wrappedValue ?? sourceData
        _workingData = State(initialValue: initial)
        _originalData = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if let image = UIImage(data: workingData) {
                        eraserCanvas(image)
                            .frame(maxWidth: .infinity)
                            .aspectRatio(4 / 5, contentMode: .fit)
                    } else {
                        ContentUnavailableView("Image unavailable", systemImage: "photo.badge.exclamationmark")
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("Eraser", systemImage: "eraser")
                            Spacer()
                            Button("Undo") { if !strokes.isEmpty { strokes.removeLast() } }.disabled(strokes.isEmpty)
                            Button("Reset") { workingData = originalData; strokes = []; activeStroke = [] }
                        }.font(.subheadline.weight(.semibold))
                        Slider(value: $brushFraction, in: 0.025...0.18) { Text("Eraser size") }
                        Text("Drag over anything you want removed. Neutral gray represents transparency; it is not saved into the image.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding().background(WearwellTheme.paper, in: RoundedRectangle(cornerRadius: 16))

                    VStack(alignment: .leading, spacing: 10) {
                        Label("Describe a small edit", systemImage: "text.bubble").font(.subheadline.weight(.semibold))
                        TextField("Example: remove the loose thread at the hem", text: $instruction, axis: .vertical)
                            .lineLimit(2...4).textFieldStyle(.roundedBorder)
                        Button {
                            KeyboardController.dismiss()
                            Task { await applyTextEdit() }
                        } label: {
                            HStack { Spacer(); if applyingEdit { ProgressView() } else { Label("Apply text edit", systemImage: "sparkles") }; Spacer() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || applyingEdit || hosted.status != .available)
                        if let job = editJob, applyingEdit {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(job.stage ?? "Sending edit…").font(.caption.weight(.semibold))
                                if job.state == "queued", let position = job.queuePosition {
                                    Text(position == 1 ? "Next in line" : "#\(position) in line").font(.caption2).foregroundStyle(.secondary)
                                }
                                if let estimate = job.estimatedSecondsRemaining {
                                    Text("Estimated time remaining: \(duration(estimate))").font(.caption2).foregroundStyle(.secondary)
                                } else {
                                    Text("Estimating time remaining…").font(.caption2).foregroundStyle(.secondary)
                                }
                                Text("You can close this editor or lock your phone; the hosted worker will keep working.")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        if hosted.status != .available {
                            Text("Sign in to hosted Wearwell to use text edits. The eraser works offline.").font(.caption).foregroundStyle(.secondary)
                        }
                        if let error { Text(error).font(.caption).foregroundStyle(.red) }
                        Text("AI edits are approximate. Review the result before saving.").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding().background(WearwellTheme.paper, in: RoundedRectangle(cornerRadius: 16))
                }.padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .background(WearwellTheme.cream)
            .navigationTitle("Edit cutout").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { saveAndDismiss() } }
            }
            .keyboardDismissToolbar()
        }
    }

    private func eraserCanvas(_ image: UIImage) -> some View {
        GeometryReader { proxy in
            let imageRect = aspectFitRect(imageSize: image.size, in: proxy.size)
            ZStack {
                WearwellTheme.previewSurface.frame(width: imageRect.width, height: imageRect.height)
                    .position(x: imageRect.midX, y: imageRect.midY)
                ZStack {
                    Image(uiImage: image).resizable().frame(width: imageRect.width, height: imageRect.height)
                        .position(x: imageRect.midX, y: imageRect.midY)
                    Canvas { context, _ in
                        context.blendMode = .destinationOut
                        for stroke in strokes + (activeStroke.isEmpty ? [] : [activeStroke]) {
                            var path = Path()
                            if let first = stroke.first {
                                let point = denormalize(first, in: imageRect)
                                path.move(to: point)
                                for value in stroke.dropFirst() { path.addLine(to: denormalize(value, in: imageRect)) }
                                if stroke.count == 1 {
                                    let diameter = brushFraction * min(imageRect.width, imageRect.height)
                                    path.addEllipse(in: CGRect(x: point.x - diameter / 2, y: point.y - diameter / 2, width: diameter, height: diameter))
                                    context.fill(path, with: .color(.black))
                                } else {
                                    context.stroke(path, with: .color(.black), style: StrokeStyle(lineWidth: brushFraction * min(imageRect.width, imageRect.height), lineCap: .round, lineJoin: .round))
                                }
                            }
                        }
                    }
                }.compositingGroup()
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard imageRect.contains(value.location) else { return }
                activeStroke.append(normalize(value.location, in: imageRect))
            }.onEnded { _ in
                if !activeStroke.isEmpty { strokes.append(activeStroke) }
                activeStroke = []
            })
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.black.opacity(0.08)))
        }
    }

    private func applyTextEdit() async {
        guard let current = renderedData() else { return }
        applyingEdit = true; error = nil
        defer { applyingEdit = false }
        do {
            let requestedEdit = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
            let edited: Data
            do {
                var job = try await hosted.submitCatalogEdit(imageData: current, instruction: requestedEdit)
                editJob = job
                while ["queued", "processing"].contains(job.state) {
                    try await Task.sleep(for: .seconds(2))
                    job = try await hosted.catalogEditJob(id: job.id)
                    editJob = job
                }
                guard job.state == "complete", let encoded = job.result?.imageBase64, let result = Data(base64Encoded: encoded) else {
                    throw CatalogEditError.failed(job.error ?? "The edit could not be completed.")
                }
                edited = result
            } catch HostedError.jobNotFound {
                // Older hosted builds expose the direct edit endpoint but not
                // durable catalog-edit jobs. Keep edits working until it restarts.
                editJob = nil
                edited = try await hosted.editCatalog(imageData: current, instruction: requestedEdit)
            }
            let cutout = await Task.detached(priority: .userInitiated) {
                guard let image = UIImage(data: edited) else { return edited }
                return AssetStore.preparedCollageImage(from: image).pngData() ?? edited
            }.value
            workingData = cutout
            imageData = cutout
            strokes = []; activeStroke = []; instruction = ""
        } catch { self.error = error.localizedDescription }
    }

    private func duration(_ seconds: Int) -> String {
        if seconds < 45 { return seconds <= 5 ? "a few seconds" : "less than a minute" }
        return "about \(Int(ceil(Double(seconds) / 60))) min"
    }

    private func saveAndDismiss() {
        imageData = renderedData()
        dismiss()
    }

    private func renderedData() -> Data? {
        guard let image = UIImage(data: workingData) else { return nil }
        return ManualImageEraser.erase(image, strokes: strokes + (activeStroke.isEmpty ? [] : [activeStroke]), brushFraction: brushFraction)?.pngData()
    }

    private func aspectFitRect(imageSize: CGSize, in container: CGSize) -> CGRect {
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2, width: size.width, height: size.height)
    }
    private func normalize(_ point: CGPoint, in rect: CGRect) -> CGPoint { CGPoint(x: (point.x - rect.minX) / rect.width, y: (point.y - rect.minY) / rect.height) }
    private func denormalize(_ point: CGPoint, in rect: CGRect) -> CGPoint { CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height) }
}

private enum CatalogEditError: LocalizedError {
    case failed(String)
    var errorDescription: String? { if case .failed(let message) = self { message } else { nil } }
}

enum ManualImageEraser {
    static func erase(_ source: UIImage, strokes: [[CGPoint]], brushFraction: Double) -> UIImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1; format.opaque = false
        return UIGraphicsImageRenderer(size: source.size, format: format).image { renderer in
            source.draw(in: CGRect(origin: .zero, size: source.size))
            let context = renderer.cgContext
            context.setBlendMode(.clear)
            context.setLineCap(.round); context.setLineJoin(.round)
            context.setLineWidth(brushFraction * min(source.size.width, source.size.height))
            for stroke in strokes {
                guard let first = stroke.first else { continue }
                let start = CGPoint(x: first.x * source.size.width, y: first.y * source.size.height)
                if stroke.count == 1 {
                    let diameter = brushFraction * min(source.size.width, source.size.height)
                    context.fillEllipse(in: CGRect(x: start.x - diameter / 2, y: start.y - diameter / 2, width: diameter, height: diameter))
                } else {
                    context.beginPath(); context.move(to: start)
                    for point in stroke.dropFirst() { context.addLine(to: CGPoint(x: point.x * source.size.width, y: point.y * source.size.height)) }
                    context.strokePath()
                }
            }
        }
    }
}
