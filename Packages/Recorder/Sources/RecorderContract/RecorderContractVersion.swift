/// The version of the recorder contract (`RecorderCommand`, `RecorderSnapshot`,
/// `RecorderOutcome`). A link between two devices exchanges it first: a new action, phase or
/// field that an older build cannot decode raises it.
public enum RecorderContractVersion {
    public static let current = 1
}
