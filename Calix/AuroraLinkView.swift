import AVFoundation
import SwiftUI
import UIKit

struct AuroraLinkView: View {
    let library: CalixLibrary
    var initialCode = ""
    @Environment(\.scenePhase) private var scene
    @State private var code = ""
    @State private var receipt = ""
    @State private var issue: LocalizedStringKey?
    @State private var state: LocalizedStringKey = "연동 대기"
    @State private var scan = false
    @State private var transfer: Task<Void, Never>?

    var body: some View {
        VesperPage {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "laptopcomputer.and.iphone")
                        .font(.system(size: 25, weight: .medium))
                        .frame(width: 48, height: 48)
                        .foregroundStyle(library.data.preferences.theme.accent)
                        .background(library.data.preferences.theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Calix Aurora").font(.headline)
                        Text(state).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if transfer != nil { ProgressView().accessibilityLabel("연동 중") }
                }
                if let sync = library.data.auroraLink?.lastSync {
                    LabeledContent("최근 연동") { Text(sync.formatted(date: .abbreviated, time: .shortened)) }
                        .font(.footnote)
                }
                if let count = library.data.auroraLink?.conflicts, count > 0 {
                    Label("양쪽에서 수정된 항목 \(count)개를 각각 보존했습니다.", systemImage: "exclamationmark.circle")
                        .font(.footnote)
                }
            }
            .padding(16)
            .vesperSurface()

            if transfer != nil {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Aurora에서 확인 코드 승인").font(.headline)
                    Text(receipt).font(.system(.title, design: .monospaced).weight(.semibold))
                        .accessibilityLabel(Text("확인 코드 \(receipt)"))
                    Button("취소", role: .cancel) { cancel() }.buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .vesperSurface()
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("같은 Wi-Fi에서 Aurora의 기기 연동 QR을 엽니다.").font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button { scan = true } label: {
                        Label("QR 스캔", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    SecureField("연동 주소 붙여넣기", text: $code)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(nil)
                        .accessibilityIdentifier("aurora-link-code")
                        .onSubmit(start)
                    if !code.isEmpty {
                        Button("연동 요청", action: start).buttonStyle(.bordered)
                    }
                }
                .padding(16)
                .vesperSurface()
            }
            if let issue {
                Label(issue, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.red)
            }
        }
        .navigationTitle("Aurora 연동")
        .onAppear { if code.isEmpty { code = initialCode } }
        .onDisappear { cancel() }
        .onChange(of: scene) { _, phase in if phase == .background { cancel() } }
        .sheet(isPresented: $scan) {
            NavigationStack {
                AuroraScanner { scanned in
                    scan = false
                    if let scanned { code = scanned }
                    else { issue = "카메라를 사용할 수 없습니다. 연동 주소를 붙여넣으세요." }
                }
                .navigationTitle("QR 스캔")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("닫기") { scan = false } }
                }
            }
        }
    }

    private func start() {
        guard transfer == nil, !library.locked, !library.unavailable else { return }
        issue = nil
        do {
            let pairing = try AuroraPairing(code)
            var link = library.data.auroraLink ?? AuroraLinkState(workspace: pairing.workspace)
            guard link.workspace == pairing.workspace else { throw AuroraLinkError.workspace }
            let baseline = AuroraWorkspace.collect(library.data, link)
            let baselineNickname = library.data.preferences.nickname
            let id = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            receipt = String(id.prefix(6)).uppercased()
            let offer = AuroraWorkspace.offer(library.data, link, receipt: id, name: "Calix Vesper")
            code = ""
            state = "Aurora 승인 대기"
            transfer = Task {
                do {
                    let snapshot = try await AuroraConnection.sync(pairing, offer: offer)
                    try Task.checkCancellation()
                    guard library.update({ data in
                        AuroraWorkspace.apply(snapshot, baseline: baseline, baselineNickname: baselineNickname,
                                              data: &data, link: &link)
                        data.auroraLink = link
                    }) else { throw AuroraLinkError.save }
                    state = "연동 완료"
                } catch is CancellationError {
                    state = "연동 대기"
                } catch {
                    state = "연동 대기"
                    issue = "연동하지 못했습니다. Aurora에서 QR을 다시 여세요."
                }
                transfer = nil
                receipt = ""
            }
        } catch AuroraLinkError.expired {
            issue = "QR이 만료되었습니다. Aurora에서 새 QR을 여세요."
        } catch AuroraLinkError.workspace {
            issue = "이전에 연동한 Aurora의 QR을 사용하세요."
        } catch {
            issue = "Aurora 연동 QR을 확인하세요."
        }
    }

    private func cancel() {
        transfer?.cancel()
        state = "연동 대기"
    }
}

private struct AuroraScanner: UIViewControllerRepresentable {
    var completion: (String?) -> Void

    func makeUIViewController(context: Context) -> Camera {
        Camera(onResult: completion)
    }

    func updateUIViewController(_ controller: Camera, context: Context) {}

    static func dismantleUIViewController(_ controller: Camera, coordinator: Void) { controller.stop() }

    final class Camera: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        private let session = AVCaptureSession()
        private let queue = DispatchQueue(label: "calix.vesper.scanner")
        private var preview: AVCaptureVideoPreviewLayer?
        private var completed = false
        private var active = true
        private let onResult: (String?) -> Void

        init(onResult: @escaping (String?) -> Void) {
            self.onResult = onResult
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            Task { [weak self] in
                let allowed = await AVCaptureDevice.requestAccess(for: .video)
                guard let self, self.active else { return }
                guard allowed else { self.finish(nil); return }
                self.configure()
            }
        }

        private func configure() {
            guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { finish(nil); return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { finish(nil); return }
            session.addOutput(output)
            guard output.availableMetadataObjectTypes.contains(.qr) else { finish(nil); return }
            output.metadataObjectTypes = [.qr]
            output.setMetadataObjectsDelegate(self, queue: .main)
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            layer.frame = view.bounds
            view.layer.addSublayer(layer)
            preview = layer
            queue.async { [session] in session.startRunning() }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview?.frame = view.bounds
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            for case let qr as AVMetadataMachineReadableCodeObject in metadataObjects {
                if let value = qr.stringValue, value.hasPrefix("calix-vesper://pair?") { finish(value); break }
            }
        }

        private func finish(_ value: String?) {
            guard active, !completed else { return }
            completed = true
            stop()
            onResult(value)
        }

        func stop() {
            active = false
            queue.async { [session] in if session.isRunning { session.stopRunning() } }
        }
    }
}
