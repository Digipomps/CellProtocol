// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  ShoppingHandler.swift
//  CellProtocol
//
//  Created by Kjetil Hustveit on 29/07/2025.
//
import CellBase
import Foundation


public class ShoppingHandlerCell: GeneralCell {
    
    private var cellConfiguration: CellConfiguration = CellConfiguration(name: "Shopping Handler")
    /*
     The Purpose of this is to set up subscriptions from udentity unique shopping cells and validate and store prosfs of ownership in entity
     
     */
    required init(owner: Identity) async {
        
        await super.init(owner: owner)
        //        await initialLoading()
        
        
        
        // Read storagejson - we may outsource persistence to a separate CS
        
        
        
        print("Initing Shopping Handler cell for owner: \(owner.uuid)")
        
        
        await setupPermissions(owner: owner)
        await setupKeys(owner: owner)
    }
    
    enum CodingKeys: CodingKey {
        case storage
        case cell
    }
    
    required init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        try super.init(from: decoder)
        
        // NB! This may not always work and could end up biting us in the butt at some point BEWARE!!!
        Task {
                if let vault = CellBase.defaultIdentityVault,
                   let requester = await vault.identity(for: "private", makeNewIfNotFound: true ) {
                    await setupPermissions(owner: requester)
                    await setupKeys(owner: requester)
                }
        }
        
    }
    
    public override func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try super.encode(to: encoder)
    }
    
    private func setupPermissions(owner: Identity) async  {
        self.agreementTemplate.addGrant("rw--", for: "loadShopCell")
        self.agreementTemplate.addGrant("rw--", for: "getFromShop")
        self.agreementTemplate.addGrant("rw--", for: "setInShop")
        self.agreementTemplate.addGrant("rw--", for: "buyProductInShop")
        
        // Execute get or set in subscribed cell and store result at keypath
        // This cell will only be accessed from it's owner so adding ggrants will not be necessary
        
        /*
         Buying process:
         get list of products - as CellReferences?
         ask each connected shop cell for state - or...?
         
         to get this product - you need to present proof that you've paid for it
         to pay for it seller - must present proof that ownership is changed
         
         select product
         put it in ownerhip exchange cell
         when all conditions are resolved exchange ownership of product and transfer funds
         
         get and store proof of payment
         get and store proof of ownership
         
         
         
         select product - request change of ownership -> put in into ownership transfer cell
         
         
         */
        
    }
    
    private func setupKeys(owner: Identity) async  {
        
        await addIntercept(requester: owner, intercept: { [weak self] flowElement, requester in
            guard let self = self else { return nil }
            print("Incoming flowElement to Shopping Handler: \(String(describing: try? flowElement.content.valueType().jsonString()))")
            if flowElement.properties?.type == .content {
                guard case let .object( eventObject) = flowElement.content else {
                    print("Shopping handler flow element not object")
                    return nil
                }
                
                // Claim should be stored in entity - aka identity for later retrieval
                if let originUUID = flowElement.origin {
                    if let emit = await self.getEmitterWithUUID(originUUID, requester: owner)  {
                        print("Got target cell emit: \(emit)") // Just for testing
                        do {
                            let emitOwner = try await emit.getOwner(requester: requester)
                            print("Got emit.owner: \(emitOwner.uuid)")
                        } catch {
                            print("Shhopping handler Get owner failed with error: \(error)")
                        }
                    }
                }
                
                do {
                    let shopEvent = try convertEventObjectToShopEvent(eventObject)
                    
                    if let issuerIdentity = shopEvent.issuerIdentity {
                        let issuerIdentityKeypath = "relations.identities.\(issuerIdentity.uuid)"
                        if !(await self.valueExists(at: issuerIdentityKeypath, requester: requester)) {
                            
                            _ = try await requester.set(keypath: issuerIdentityKeypath, value: .identity(issuerIdentity), requester: requester)
                            
                            if let issuer = shopEvent.claim?.issuer {
                                let issuerIdentityKeypath = "relations.issuers.\(issuer)"
                                print("issuerIdentityKeypath: \(issuerIdentityKeypath)")
                                _ = try await requester.set(keypath: issuerIdentityKeypath, value: .string(issuerIdentity.uuid), requester: requester)
                            }
                            
                            
                            if let product = shopEvent.product {
                                let entityIdValue = try await requester.get(keypath: "relations.identities.\(issuerIdentity)", requester: requester)
                                
                                
                                if case let .string(entityId) = entityIdValue,
                                   let instanceId = product["instanceId"] {// the id of the purchased product
                                    let productKeypath = "relations.\(entityId).organisation.products.purchased.\(instanceId)"
                                    _ = try await requester.set(keypath: productKeypath, value: .string(issuerIdentity.uuid), requester: requester)
                                }
                            }
                            if let claim = shopEvent.claim {
                                let claimKeypath = "proofs.claims.\(claim.id)"
                                if !(await self.valueExists(at: claimKeypath, requester: requester)) {
                                    _ = try await requester.set(keypath: claimKeypath, value: .verifiableCredential(claim), requester: requester)
                                }
                            }
                            
                            // Consider using keypath althoug it's a slightly different usecase
                            
                            
                        }
                    }
                    
                    
//                    if shopEvent.claim != nil && shopEvent.product == nil {
//                        // Bought ticket
//                        
//                        
//                    } else if shopEvent.claim != nil && shopEvent.product != nil {
//                        // Bought product
//                        
//                    }
                    
                } catch {
                    print("Shopping handler event object not convertable to ShopEvent")
                    return nil
                }
                /*
                 # Buy ticket
                    "issuerIdentity" : {},
                    "claim" : {},
                 Store at
                 relations.issuers
                 # Prove some property
                 {
                     "keypath" : "some.key.path.value",
                     "claim" : {
                         
                     },
                     "issuerIdentity" : {}
                 }

                 # buy a product
                 {
                     "product" : { "prodId" : "prodId" },
                     "ownerClaim" : { "claimId" : "claimId" },
                     "issuerIdentity": {}
                 }

                 */
                
//      
                return nil
            }
            return flowElement
        })
    }
    
    private func valueExists(at keypath: String, requester: Identity) async -> Bool {
        var exists = false
        do {
            _ = try await requester.get(keypath: keypath, requester: requester)
            exists = true
        } catch {
            print("Did not find value at: \(keypath)") // TODO omit catch
        }
        return exists
    }
    
    func loadShopCell(_ cellConfiguration: CellConfiguration, requester: Identity) async throws {
        guard let resolver = CellBase.defaultCellResolver else {
            throw CellBaseError.noResolver
        }
        _ = try await resolver.loadCell(from: cellConfiguration, into: self, requester: requester)
    }
    
    
    // Buy is the same as transfer ownership
    func buy(_ productKeypath: String) async throws -> Bool {
        
        return false
    }
    
    
    
    func loadShops() async throws  -> CellConfiguration {
        /*
         get keypath1 and store it in keypath2
         
         */
        if let cellReferences = self.cellConfiguration.cellReferences {
            for cellReference in cellReferences {
                
            }
        }
        return self.cellConfiguration
    }
    
    func storeCellConfiguration() {
        
    }
    
    func executeCellConfiguration() {
        
    }
    
    func addCellConfiguration() {
        
    }
    
    func addCellReference() {
        
    }
    
    func removeCellReference() {
        
    }
    
    
    func getTargetOwner(for payloadObject: Object) throws -> Identity {
        guard let ownerValue = payloadObject["owner"] else {
            print("Shopping handler missing payload owner")
            throw ShhoppingHandlerError.missingOwner
        }
        
        guard case let .object(ownerObject) = ownerValue else {
            print("Shopping handler payload owner not object")
            throw ShhoppingHandlerError.ownerNotObject
        }
        print("Owner Object: \(ownerObject)")
        let ownerIdentity = try self.convertOwnerObjectToIdentity(ownerObject)
        print("Owner Identity: \(ownerIdentity)")
        
        return ownerIdentity
    }
    
    func convertOwnerObjectToIdentity(_ ownerObject: Object) throws -> Identity {
        let ownerJson = try JSONEncoder().encode(ownerObject)
        let identity = try JSONDecoder().decode(Identity.self, from: ownerJson)
        
        return identity
    }
    
    func convertEventObjectToShopEvent(_ eventObject: Object) throws -> ShopEvent {
        let eventJson = try JSONEncoder().encode(eventObject)
        let shopEvent = try JSONDecoder().decode(ShopEvent.self, from: eventJson)
        
        return shopEvent
    }
}

struct ShopEvent: Codable {
    let issuerIdentity: Identity?
//    let keypath: String?
    let product: Object?
    let claim: VCClaim?
    // issuerIdentity always present?
    // product & claim = bought product
    // claim & !product =  bought ticket
}


enum ShhoppingHandlerError :  Error {
    case missingOwner
    case ownerNotObject
}
