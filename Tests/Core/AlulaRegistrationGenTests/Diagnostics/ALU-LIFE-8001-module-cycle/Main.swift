import AlulaWeb

struct InventoryModule: AlulaModule {
    let inventory: Inventory
    init(prices: PriceList) { inventory = Inventory() }
}

struct PricingModule: AlulaModule {
    let prices: PriceList
    init(inventory: Inventory) { prices = PriceList() }
}

@main struct Main {
    static func main() async {
        await Alula.run(configuration: .load(), modules: [InventoryModule.self, PricingModule.self])
    }
}
