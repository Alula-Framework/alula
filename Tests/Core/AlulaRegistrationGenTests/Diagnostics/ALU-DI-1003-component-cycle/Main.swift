import AlulaCore

@Service
struct UserService {
    @Inject var audit: AuditService
}

@Service
struct AuditService {
    @Inject var notifications: NotificationService
}

@Service
struct NotificationService {
    @Inject var users: UserService
}
