import SwiftUI
import PhotosUI
import UIKit
import ImageIO

struct ProfileEditor: View {
    @Environment(ProfileStore.self) private var profile
    @Environment(\.dismiss) private var dismiss
    @State private var draft: PlayerProfile
    @State private var photoItem: PhotosPickerItem?
    @State private var crop: CropImage?
    @State private var cameraOpen = false
    @State private var loadingPhoto = false
    @State private var error: String?
    @State private var loadTask: Task<Void, Never>?

    init(initial: PlayerProfile) { _draft = State(initialValue: initial) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Player image") {
                    PlayerAvatar(data: draft.photoData, size: 100).frame(maxWidth: .infinity)
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label(draft.photoData == nil ? "Choose from Photos" : "Change photo", systemImage: "photo")
                    }
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button("Take a photo", systemImage: "camera") { cameraOpen = true }
                    }
                    if draft.photoData != nil {
                        Button("Reposition photo", systemImage: "crop") {
                            if let data = draft.photoData, let image = UIImage(data: data) { crop = CropImage(image: image) }
                        }
                        Button("Remove photo", role: .destructive) { draft.photoData = nil }
                    }
                    if loadingPhoto { ProgressView("Loading photo…") }
                }
                Section("Identity") {
                    TextField("Display name", text: $draft.name).textContentType(.name)
                    TextField("Country or region (optional)", text: $draft.country).textContentType(.countryName)
                    Picker("Discipline", selection: $draft.discipline) {
                        ForEach(["Singles", "Doubles", "Mixed", "Multiple"], id: \.self) { Text($0).tag($0) }
                    }
                    TextField("Playing style (optional)", text: $draft.style)
                }
                Section("Measurements — optional") {
                    HStack {
                        Text("Height")
                        TextField("Not set", value: $draft.heightCM, format: .number)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                        Text("cm").foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Weight")
                        TextField("Not set", value: $draft.weightKG, format: .number)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                        Text("kg").foregroundStyle(.secondary)
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red).accessibilityAddTraits(.isStaticText) } }
            }
            .navigationTitle("Edit profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(loadingPhoto) }
            }
            .sheet(item: $crop) { source in
                PhotoCropView(image: source.image) { draft.photoData = $0 }
            }
            .fullScreenCover(isPresented: $cameraOpen) {
                CameraPicker { image in
                    cameraOpen = false
                    if let image { crop = CropImage(image: image) }
                }.ignoresSafeArea()
            }
            .onChange(of: photoItem) { _, selection in loadPhoto(selection) }
            .onDisappear { loadTask?.cancel() }
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem?) {
        loadTask?.cancel()
        guard let item else { return }
        loadingPhoto = true
        error = nil
        loadTask = Task { @MainActor in
            defer { if !Task.isCancelled { loadingPhoto = false } }
            do {
                guard let data = try await item.loadTransferable(type: Data.self), !Task.isCancelled else { return }
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 1800
                      ] as CFDictionary) else { throw PhotoError.unreadable }
                crop = CropImage(image: UIImage(cgImage: cgImage))
            } catch { self.error = "Photo could not be opened: \(error.localizedDescription)" }
        }
    }

    private func save() {
        guard draft.heightCM.map({ $0.isFinite && (50...250).contains($0) }) ?? true,
              draft.weightKG.map({ $0.isFinite && (10...400).contains($0) }) ?? true else {
            error = "Enter a height between 50 and 250 cm and a weight between 10 and 400 kg, or leave them blank."
            return
        }
        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        do { try profile.updateProfile(draft); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}

private struct CropImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

private enum PhotoError: LocalizedError {
    case unreadable
    var errorDescription: String? { "This image format could not be decoded." }
}

struct PhotoCropView: View {
    let image: UIImage
    let onSave: (Data) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var zoom = 1.0
    @State private var horizontal = 0.0
    @State private var vertical = 0.0
    @GestureState private var drag = CGSize.zero
    @State private var error: String?
    private let side: CGFloat = 280

    private var renderedSize: CGSize {
        let fit = max(side / image.size.width, side / image.size.height) * zoom
        return CGSize(width: image.size.width * fit, height: image.size.height * fit)
    }
    private var offset: CGSize {
        CGSize(width: min(1, max(-1, horizontal)) * max(0, renderedSize.width - side) / 2,
               height: min(1, max(-1, vertical)) * max(0, renderedSize.height - side) / 2)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Text("Position your photo inside the circle.").foregroundStyle(.secondary)
                    Image(uiImage: image).resizable()
                        .frame(width: renderedSize.width, height: renderedSize.height)
                        .offset(x: offset.width + drag.width, y: offset.height + drag.height)
                        .frame(width: side, height: side).clipped()
                        .overlay { Circle().strokeBorder(.white, lineWidth: 3) }
                        .clipShape(.circle)
                        .gesture(DragGesture().updating($drag) { value, state, _ in state = value.translation }
                            .onEnded { value in
                                let width = max(1, (renderedSize.width - side) / 2)
                                let height = max(1, (renderedSize.height - side) / 2)
                                horizontal = min(1, max(-1, horizontal + value.translation.width / width))
                                vertical = min(1, max(-1, vertical + value.translation.height / height))
                            })
                        .accessibilityLabel("Profile photo crop preview")
                    VStack(alignment: .leading) {
                        Text("Zoom")
                        Slider(value: $zoom, in: 1...3).accessibilityLabel("Photo zoom")
                        Text("Horizontal position")
                        Slider(value: $horizontal, in: -1...1).accessibilityLabel("Horizontal photo position")
                        Text("Vertical position")
                        Slider(value: $vertical, in: -1...1).accessibilityLabel("Vertical photo position")
                    }
                    Button("Reset crop") { zoom = 1; horizontal = 0; vertical = 0 }
                    if let error { Text(error).foregroundStyle(.red) }
                }.padding(20)
            }
            .navigationTitle("Crop photo").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Use photo") { cropImage() } }
            }
        }
    }

    private func cropImage() {
        let size = CGSize(width: 768, height: 768)
        let ratio = size.width / side
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let result = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(x: (side - renderedSize.width) / 2 * ratio + offset.width * ratio,
                                  y: (side - renderedSize.height) / 2 * ratio + offset.height * ratio,
                                  width: renderedSize.width * ratio, height: renderedSize.height * ratio))
        }
        guard let data = result.jpegData(compressionQuality: 0.88) else { error = "The cropped image could not be saved."; return }
        onSave(data)
        dismiss()
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    let onResult: (UIImage?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onResult: onResult) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = .camera
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onResult: (UIImage?) -> Void
        init(onResult: @escaping (UIImage?) -> Void) { self.onResult = onResult }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onResult(nil) }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onResult(info[.originalImage] as? UIImage)
        }
    }
}
