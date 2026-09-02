import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum PairCommand {
    static func run(_ args: [String]) async throws {
        guard let sub = args.first else {
            fputs("usage: attention-cli pair <invite|join|status|forget>\n", stderr)
            exit(1)
        }
        let rest = Array(args.dropFirst())
        switch sub {
        case "invite": try await invite(Args(rest))
        case "join":   try await join(Args(rest))
        case "status": status()
        case "forget": forget()
        default:
            fputs("unknown pair subcommand: \(sub)\n", stderr)
            exit(1)
        }
    }

    // MARK: - invite

    private static func invite(_ args: Args) async throws {
        // 2.0 pairing hands out a CKShare URL for this device's inbox zone. This tool has
        // no zone to share and no way to accept one, so it can't mint a usable invite —
        // failing here beats printing a QR code that no phone can act on.
        throw CLIError.supersededByPrivateZones
    }

    private static func join(_ args: Args) async throws {
        // Joining now means accepting a CKShare, which needs the iCloud entitlement a
        // macOS `tool` target can't embed — the same limitation that already stops this
        // tool reaching CloudKit at all (issue #60).
        throw CLIError.supersededByPrivateZones
    }

    private static func status() {
        guard let state = CLIState.load() else {
            print("No pair state. Run 'pair invite' or 'pair join' first.")
            return
        }
        print("pairKey:         \(state.pairKey)")
        print("myDeviceID:      \(state.myDeviceID)")
        print("myName:          \(state.myName)")
        print("partnerDeviceID: \(state.partnerDeviceID)")
        print("partnerName:     \(state.partnerName)")
    }

    // MARK: - forget

    private static func forget() {
        do {
            try CLIState.clear()
            print("State file deleted.")
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            print("No state file found.")
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    // MARK: - QR helpers

    private static func generateQRCode(from payload: String, to url: URL) throws {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let raw = filter.outputImage else { throw CLIError.qrCodeFailed }
        let scale: CGFloat = 10
        let scaled = raw.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { throw CLIError.qrCodeFailed }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw CLIError.qrCodeFailed }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else { throw CLIError.qrCodeFailed }
    }

    private static func defaultName() -> String {
        Host.current().localizedName ?? "AttentionCLI"
    }
}
