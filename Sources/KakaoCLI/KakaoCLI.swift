import ArgumentParser

@main
struct KakaoCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "kakaocli",
        abstract: "KakaoTalk CLI for AI agents",
        version: "0.8.0",
        subcommands: [
            AuthCommand.self,
            CandidatesCommand.self,
            ChatsCommand.self,
            ContextCommand.self,
            HarvestCommand.self,
            InspectCommand.self,
            LoginCommand.self,
            MessagesCommand.self,
            PermissionsCommand.self,
            QueryCommand.self,
            SchemaCommand.self,
            SearchCommand.self,
            SendCommand.self,
            StatusCommand.self,
            SyncCommand.self,
        ]
    )
}
