import DexCore
import Foundation

extension SessionStore {
    // Dispatching, and the rows that stand in until the list catches up

    private struct LaunchSettings {
        let model: String?
        let effort: String?
    }

    /// What a new session is started with: the composer's picks, with Default
    /// resolved against `defaults`, the folder it is going to.
    private func launchSettings(defaults: HostDefaults?) -> LaunchSettings {
        // A settings file names a model as an alias, and an alias is what to
        // send: it still carries the context width, which is the thing the CLI's
        // display name has had stripped off it by the time this app reads one.
        // Resolving Default through that name instead would take a file pinning
        // narrow `opus` deliberately and launch it at 1M, since `opus` and
        // `opus[1m]` arrive as one string — a silent upgrade, wearing the
        // Default marker. Where no file names one there is no alias to send:
        // the CLI's own built-in default is not a thing this app can spell, so
        // Default sends no flag and the CLI resolves the cascade the marker was
        // read from.
        let pinned = Self.pinnedModel(in: defaults)
        return LaunchSettings(
            model: composer.model.hostModelID ?? pinned,
            effort: composer.effort.launching(default: defaultEffort(in: defaults))
        )
    }

    /// A hosted session's `start_session`. Started the way the composer would
    /// start it, but left in the list rather than opened: you are reading
    /// something else, and the session that asked may start several.
    func launchRequested(_ request: HostLaunch) {
        let target: HostSessions = host
        // Default resolves per folder, and the composer only ever asked about its own.
        let fresh = target.defaults(for: request.cwd) == nil
        if fresh { target.resolveDefaults(cwd: request.cwd) }
        Task { [weak self] in
            for _ in 0..<40 where fresh {
                guard self != nil, target.defaults(for: request.cwd) == nil else { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            self?.startLaunch(
                request, through: target
            )
        }
    }

    private func startLaunch(
        _ request: HostLaunch, through target: HostSessions
    ) {
        let launch = launchSettings(defaults: target.defaults(for: request.cwd))
        let started = target.dispatch(
            cwd: request.cwd,
            prompt: request.prompt,
            model: launch.model,
            permissionMode: "auto",
            name: request.name,
            outputStyle: preferences.outputStyle.hostStyleID,
            effort: launch.effort,
            origin: SessionOrigin(parent: request.parent),
            started: { [weak self] outcome in
                guard let self else { return }
                switch outcome {
                case .started(let key):
                    self.dispatches.launched(key, as: self.composer.model)
                    self.host.answerLaunch(request.launchId, key: key)
                case .refused(let why):
                    self.host.answerLaunch(request.launchId, error: why ?? "the host would not start it")
                case .notSent(let why):
                    self.host.answerLaunch(request.launchId, error: why)
                }
            }
        )
        if !started {
            host.answerLaunch(request.launchId, error: target.unavailable ?? "the host is not running")
        }
    }

    /// Starts a session. The row arrives on the socket, so the list catches it
    /// through `hostChanged` without a fetch. When the host never came up, the
    /// failure is reported rather than worked around: the app spawns and
    /// retries the host itself, so a missing one is something to fix.
    func dispatchHosted(
        prompt: String, name: String?, directory: String
    ) {
        // The row does not exist until the host says it does, and a composer
        // that just empties itself reads as a message sent into the void.
        let pending = PendingDispatch(
            prompt: prompt,
            project: directory,
            knownRowIDs: Set(snapshot.rows.map(\.rowID))
        )

        let launch = launchSettings(defaults: composerDefaults)
        let started = host.dispatch(
            cwd: directory,
            prompt: prompt,
            model: launch.model,
            // Auto always: no mode is not auto — it lands the CLI's ask-first default.
            permissionMode: "auto",
            // Only a name that was chosen. What was typed used to be sent as
            // one, which no row ever wore — the host repeats it on its welcome
            // and nowhere else, so it surfaced only after a restart, and then as
            // a title saying what the line beneath it already said.
            name: name,
            outputStyle: preferences.outputStyle.hostStyleID,
            effort: launch.effort,
            started: { [weak self] launch in
                guard let self else { return }
                guard case .started(let key) = launch else {
                    self.dispatches.drop(pending.id)
                    self.toasts.report(
                        ActionOutcome(
                            label: "New session",
                            succeeded: false,
                            message: Self.refusal("the host would not start it", launch)
                        )
                    )
                    return
                }
                // The host's key is the row's id, so the pending one claims the
                // row the moment it arrives rather than guessing by project.
                //
                // The pick, not what Default resolved to: the resolved name is
                // read in the app's own directory and Default resolves per
                // project, so filing it here would let the chip assert another
                // folder's answer. A Default launch names nothing and waits the
                // beat for init, which is the only word that is true per folder.
                self.dispatches.launched(key, as: self.composer.model)
                self.dispatches.bind(rowID: key, to: pending.id)
                self.resolvePendingDispatches()
            }
        )

        guard started else {
            toasts.report(
                ActionOutcome(
                    label: "New session",
                    succeeded: false,
                    message: host.unavailable
                        ?? "the host is not running"
                )
            )
            return
        }

        dispatches.hold(pending)
    }

    /// What the composer does with what you typed.
    ///
    /// Two ends for one gesture: the socket while the host has the session, and
    /// a resume when it doesn't. Typing is the whole of the second, because a
    /// resumed session sits silent until it is handed something to say — there
    /// was never a moment to reopen it in that wasn't this one.
    func sendToHosted(key: String, text: String) {
        switch hostedArchive.delivery(forKey: key, live: Set(host.sessions.keys)) {
        case .send:
            host.send(key: key, text: text)

        case .resume(let entry):
            resume(entry, saying: text)

        case .gone:
            toasts.report(
                ActionOutcome(
                    label: "Send",
                    succeeded: false,
                    message: "that session is gone and there is nothing to pick up"
                )
            )
        }
    }

    /// Started under the key it had, so what comes back is the row you were
    /// looking at rather than a stranger beside it.
    ///
    /// The reply says only that the request was taken. The host answers `start`
    /// before the SDK has opened anything, so a cwd that has gone or a
    /// transcript the CLI has since retired both come back `ok` and fail a
    /// second later as an exit — which is why what you typed is held here until
    /// the session is actually up.
    private func resume(_ entry: HostedArchive.Entry, saying text: String) {
        guard dispatches.beginResume(entry.key, saying: text) else { return }

        let model = SessionModel(stored: entry.model)
        dispatches.launched(entry.key, as: model)
        let started = host.dispatch(
            cwd: entry.cwd,
            prompt: text,
            model: entry.model,
            // Auto here too, not the recorded mode: with the mode UI gone, a
            // session brought back in plan or default is invisible and immovable.
            permissionMode: "auto",
            name: entry.name,
            // How it was writing, which the app's own pick would override for
            // every row at once: the style is one app-wide setting, so reading
            // it off the picker would rewrite the voice of a conversation
            // already half-written. Recorded as the CLI resolved it, and
            // `default` normalises back to sending nothing.
            outputStyle: OutputStyle(stored: entry.outputStyle).hostStyleID,
            // The level it was running at, not the one the files resolve to
            // now: sending nothing here is Default, so a session started at low
            // came back at whatever `effortLevel` a settings file happened to
            // say — a change of behaviour with nothing on screen to say so.
            effort: EffortLevel(stored: entry.effort).launchable.hostEffortID,
            resume: entry.sessionId,
            key: entry.key,
            started: { [weak self] launch in
                if case .started = launch { return }
                self?.dispatches.resumeFailed(
                    entry.key,
                    because: Self.refusal("the host would not pick that session up", launch)
                )
            }
        )
        guard started else {
            dispatches.resumeFailed(entry.key, because: host.unavailable ?? "the host is not running")
            return
        }
        dispatches.expireResume(entry.key)
    }

    /// Anything typed while a resumed session was coming up is said now, in the
    /// order it was typed.
    func resumeArrived(_ key: String) {
        guard let pending = dispatches.resumeArrived(key) else { return }
        for message in pending { host.send(key: key, text: message) }
    }

    func resolvePendingDispatches() {
        guard let claims = dispatches.claim(in: snapshot.rows) else { return }

        // Each pane opens on the one it was waiting on, however many land at
        // once. Go read something else meanwhile and it stays where you put it.
        if !claims.claimed.isEmpty {
            for claim in claims.claimed { show(claim.row, opening: claim.dispatch.prompt) }
        } else if let arrived = claims.arrived {
            reveal(arrived.row)
            links.scroll(to: arrived.row)
        }
    }

    /// The host's own words after the app's account of the failure, where there
    /// are any. They are the whole point of the sentence: a start that fails has
    /// no row, no transcript and nothing else to say why.
    private static func refusal(_ what: String, _ launch: HostSessions.Launch) -> String {
        if case .notSent(let why) = launch { return why }
        guard case .refused(let why) = launch, let why, !why.isEmpty else { return what }
        return "\(what) — \(why)"
    }
}
