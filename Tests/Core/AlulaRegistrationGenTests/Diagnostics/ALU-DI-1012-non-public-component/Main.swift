import AlulaCore
import Billing

@Service
struct Checkout {
    @Inject var invoices: InvoiceService
}
