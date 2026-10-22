/// The version of the recorder contract (`RecorderCommand`, `RecorderSnapshot`,
/// `RecorderOutcome`). A link between two devices exchanges it first and checks it before it
/// decodes anything else: a new action, phase or required field that an older build cannot decode
/// raises it. Within one version, `accepts` drops kinds it does not know and `RecorderFailure`
/// reads unknown reasons as `unknown`, so additive changes stay readable.
public enum RecorderContractVersion {
    public static let current = 1
}
