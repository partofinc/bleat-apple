extension String {
    /// The path without a trailing `/`, except `/` itself. One rule for home,
    /// a space's folder and a typed directory, so they compare alike.
    var droppingTrailingSlash: String {
        count > 1 && hasSuffix("/") ? String(dropLast()) : self
    }
}
