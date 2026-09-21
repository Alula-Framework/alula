import Configuration

/// `ConfigValue`, reachable from a file that also imports FlightConfig.
///
/// swift-configuration's module is named `Configuration` and
/// `FlightConfig.Configuration` is a struct, so in any file importing both,
/// `Configuration.ConfigValue` resolves against the struct and fails. This
/// file imports only the module, so the name binds to the right thing, and
/// the alias carries it across.
typealias ProviderValue = ConfigValue
