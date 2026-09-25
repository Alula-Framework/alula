import AlulaWeb

struct AlulaChannelsModule: AlulaModule {
    init(channels: [ChannelRegistration] = []) throws {}
}

struct ChatModule: AlulaModule {
    let channels: [ChannelRegistration] = []
}

@main struct Main {
    static func main() async {
        await Alula.run(configuration: .load(), modules: [ChatModule.self])
    }
}
