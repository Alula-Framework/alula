import AlulaCore

@Service
struct Mailer {
    @ConfigValue("mail.host") var host: String
}

let configuration = try Configuration.load(prefix: "relay")
