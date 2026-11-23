import PhotosUI
import SwiftUI
import UIKit
import OiseauCore

/// « Prendre une photo » / « Choisir une image » (Android: ui/components/PhotoInput.kt):
/// the camera, or the system photo picker (which needs no library permission). The
/// picked image is prepared (size, rotation, JPEG) before it is handed back.
struct PhotoInput: View {
    @Environment(AppModel.self) private var app
    let photo: Data?
    let onPicked: (Data?) -> Void
    @State private var item: PhotosPickerItem?
    @State private var camera = false

    init(photo: Data?, onPicked: @escaping (Data?) -> Void) {
        self.photo = photo
        self.onPicked = onPicked
    }

    var body: some View {
        VStack(spacing: 10) {
            if let photo, let image = UIImage(data: photo) {
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(maxWidth: .infinity).frame(height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: Zine.radiusMedium))
                    .overlay(RoundedRectangle(cornerRadius: Zine.radiusMedium).stroke(Zine.ink, lineWidth: Zine.lineWidth))
                    .accessibilityLabel(L("hunt_chosen_photo"))
            }
            HStack(spacing: 10) {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    OpButton(title: L("photo_take"), icon: "camera", variant: photo == nil ? .primary : .secondary, fullWidth: true) { camera = true }
                }
                PhotosPicker(selection: $item, matching: .images) {
                    HStack(spacing: 8) {
                        LucideIcon("image", size: 20)
                        Text(L("photo_pick"))
                    }
                }
                .buttonStyle(OpButtonStyle(variant: .secondary, fullWidth: true))
                .accessibilityIdentifier("photo.pick")
            }
        }
        .onChange(of: item) { _, picked in
            guard let picked else { return }
            Task {
                let data = try? await picked.loadTransferable(type: Data.self)
                if let data { onPicked(await app.photoPreparer.prepare(data)) } else { onPicked(nil) }
                item = nil
            }
        }
        .fullScreenCover(isPresented: $camera) {
            CameraView { image in
                camera = false
                guard let jpeg = image?.jpegData(compressionQuality: 0.95) else { return }
                Task { onPicked(await app.photoPreparer.prepare(jpeg)) }
            }
            .ignoresSafeArea()
        }
    }
}

/// The system camera.
private struct CameraView: UIViewControllerRepresentable {
    let onDone: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onDone) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onDone: (UIImage?) -> Void
        init(_ onDone: @escaping (UIImage?) -> Void) { self.onDone = onDone }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onDone(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onDone(nil) }
    }
}
