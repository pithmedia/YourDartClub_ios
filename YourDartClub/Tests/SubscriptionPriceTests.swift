import XCTest
@testable import DartCore

final class SubscriptionPriceTests: XCTestCase {
    let monthly = "com.yourdartclub.iphone.team.monthly"
    let yearly = "com.yourdartclub.iphone.team.yearly"
    func testKnownSandboxDollarCatalogUsesEuropeanReference() {
        let month = SubscriptionPriceDisplay(productID:monthly,amount:9,currency:"USD",sandbox:true)
        let year = SubscriptionPriceDisplay(productID:yearly,amount:90,currency:"USD",sandbox:true)
        XCTAssertEqual(month.currency,"EUR")
        XCTAssertTrue(month.usesEuropeanReference)
        XCTAssertEqual(month.amount,10)
        XCTAssertEqual(year.amount,100)
        XCTAssertEqual(month.amount * 12 - year.amount,20)
    }
    func testBritishPricesArePreservedInSandboxAndProduction() {
        for sandbox in [true,false] {
            let price = SubscriptionPriceDisplay(productID:monthly,amount:Decimal(string:"8.49")!,currency:"GBP",sandbox:sandbox)
            XCTAssertEqual(price.currency,"GBP")
            XCTAssertEqual(price.amount,Decimal(string:"8.49")!)
            XCTAssertFalse(price.usesEuropeanReference)
        }
    }
    func testProductionAndOtherProductsAreNeverOverridden() {
        for (id,sandbox,currency) in [(monthly,false,"USD"),("other",true,"USD"),(monthly,true,"EUR")] {
            let price = SubscriptionPriceDisplay(productID:id,amount:12,currency:currency,sandbox:sandbox)
            XCTAssertEqual(price.amount,12)
            XCTAssertEqual(price.currency,currency)
            XCTAssertFalse(price.usesEuropeanReference)
        }
    }
}
