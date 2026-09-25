import AlulaCore

@Service
struct Mailer {
    @ConfigValue("mail.host") var host: String
}
