import Foundation

/// Where Linear, Notion and Slack tokens are kept.
public enum ConnectionTokens {
    public static let store: any TokenStore = AppKeychain()
    public static let whereKept = "Tokens are kept in this Mac's keychain, where only Dex reads them."
}
