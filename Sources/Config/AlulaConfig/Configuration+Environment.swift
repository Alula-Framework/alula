import AlulaConfigCore

import class Foundation.ProcessInfo

extension Configuration {
    /// The environment this deployment *stated*, or `nil` when it stated none.
    ///
    /// ``environment`` answers "which overlay did we load", and an unset
    /// `ALULA_ENV` answers `dev` — the right file for a laptop. It is the wrong
    /// answer to "may this process publish what only a developer should see",
    /// because a production box that forgot the variable gives it too. This
    /// separates the two: an environment counts as stated when `ALULA_ENV`
    /// was set, or when code named one (`Configuration.load(environment:)`,
    /// `Configuration(sources:environment:)`).
    ///
    /// A configuration assembled by hand without an environment has not
    /// decided, so the variable is read from `processEnvironment`, the same
    /// read `load` makes.
    public func declaredEnvironment(
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AlulaEnvironment? {
        switch environmentOrigin {
        case .declared:
            return environment
        case .defaulted:
            return nil
        case .unknown:
            guard let raw = processEnvironment[prefix.environmentVariable], !raw.isEmpty else {
                return nil
            }
            return AlulaEnvironment(raw)
        }
    }

    /// Whether developer-facing surfaces — the OpenAPI document, the actuator
    /// dashboard — are published by default: only when the environment was
    /// stated *and* is a development one (`AlulaEnvironment.isDevelopment`).
    ///
    /// Unset is not development here, though it selects the `dev` overlay: a
    /// production deployment that forgets `ALULA_ENV` must not start
    /// describing itself. A development machine says `ALULA_ENV=dev` (which
    /// `alula dev` does not do for it), or turns the surface on by its own key.
    public func isExplicitlyDevelopment(
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        declaredEnvironment(processEnvironment: processEnvironment)?.isDevelopment ?? false
    }
}
