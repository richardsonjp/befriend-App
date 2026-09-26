//
//  SkinShop.swift
//  PetCore
//
//  Paid skins (M9): each is a non-consumable In-App Purchase. StoreKit sells it; the backend checks the signed
//  transaction and grants the skin to the befriend account, so it follows the account to every device.
//

import Foundation
import Observation
import os
import StoreKit

/// A skin for sale, as `GET /skins/catalog` lists it.
public nonisolated struct CatalogSkin: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let tier: Int
    public let productId: String
    /// idle's first frame, a 32×32 PNG.
    public let preview: Data?
    public let owned: Bool
}

@Observable
public final class SkinShop {
    private static let log = Logger(subsystem: "com.richardsonjp.befriend", category: "shop")

    public struct Item: Identifiable {
        public let skin: CatalogSkin
        /// Nil until App Store Connect has the product (or offline): it can't be bought yet.
        public let product: Product?
        public var id: String { skin.id }
    }

    public private(set) var items: [Item] = []
    /// The product being bought or restored, for a spinner.
    public private(set) var busy: String?
    public private(set) var message: String?
    /// A purchase unlocked a skin: the store syncs the account's skins.
    @ObservationIgnored public var onUnlocked: () -> Void = {}

    private let api: APIClient
    @ObservationIgnored private var updates: Task<Void, Never>?

    public init(api: APIClient) {
        self.api = api
    }

    /// Picks up purchases finished outside the app (Ask to Buy, another device, a crash mid-purchase).
    public func start() {
        guard updates == nil else { return }
        updates = Task { [weak self] in
            for await verification in Transaction.updates {
                await self?.redeem(verification)
            }
        }
    }

    public func load() async {
        do {
            let catalog = try await api.skinCatalog()
            let products = try await Product.products(for: catalog.map(\.productId))
            items = catalog.map { skin in Item(skin: skin, product: products.first { $0.id == skin.productId }) }
        } catch {
            Self.log.error("Loading the shop failed: \(String(describing: error), privacy: .public)")
        }
    }

    public func buy(_ item: Item) async {
        guard let product = item.product, busy == nil else { return }
        busy = item.id
        message = nil
        defer { busy = nil }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                await redeem(verification)
            case .pending:
                message = "Waiting for approval. Your skin unlocks once it's approved."
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            message = "The purchase didn't go through. Please try again."
        }
    }

    /// Sends every purchase this Apple Account made to the backend again (a new device, or a new befriend account).
    public func restore() async {
        busy = "restore"
        message = nil
        defer { busy = nil }
        try? await AppStore.sync()
        for await verification in Transaction.currentEntitlements {
            await redeem(verification)
        }
        await load()
    }

    /// The backend grants the skin; the transaction is finished once it has answered for good (a network error
    /// leaves it for `Transaction.updates` to retry).
    private func redeem(_ verification: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = verification else {
            message = "That purchase couldn't be verified."
            return
        }
        do {
            _ = try await api.redeemPurchase(signedTransaction: verification.jwsRepresentation)
            await transaction.finish()
            onUnlocked()
            await load()
        } catch APIError.server(status: 409, _, _) {
            await transaction.finish()
            message = "This purchase already unlocked the skin on another befriend account."
        } catch APIError.server(let status, _, _) where (400..<500).contains(status) {
            await transaction.finish()
            message = "That purchase couldn't be verified."
        } catch {
            Self.log.error("Redeeming a purchase failed: \(String(describing: error), privacy: .public)")
        }
    }
}
