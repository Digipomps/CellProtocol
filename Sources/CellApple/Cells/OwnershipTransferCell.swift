// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  OwnershipTransferCell.swift
//  CellProtocol
//
//  Created by Kjetil Hustveit on 31/07/2025.
//
import Foundation
import CellBase



class OwnershipTransferCell: GeneralCell {
    // must embed target for ownership transfer
    // must contain conditions for the transfer
    //
    // First set target product
    // Then start to fulfill conditions
    // When all conditions are resolved - transfer ownerhip
    var targetCell: Emit?
    var targetIdentity: Identity?
    var sourceIdentity: Identity?
    
    
    required init(owner: Identity) async {
       
        await super.init(owner: owner)
//        await initialLoading()
        
        

        // Read storagejson - we may outsource persistence to a separate CS
        
        
        
        print("Initing Ownership transfer cell for owner: \(owner.uuid)")
       
        
        await setupPermissions(owner: owner)
        await setupKeys(owner: owner)
    }
    
    required init(from decoder: any Decoder) throws {
        fatalError("init(from:) has not been implemented")
    }
    
    private func setupPermissions(owner: Identity) async  {
        self.agreementTemplate.addGrant("rw--", for: "configure")
        self.agreementTemplate.addGrant("rw--", for: "addCondition")
        
        
    }
    
    private func setupKeys(owner: Identity) async  {
        
        await addIntercept(requester: owner, intercept: { flowElement, requester in
            //                print("Incoming flowElement to Keypath storage (PDS)")
            
            // Check for VC and keypath
            // Store VC at keypath
            return nil
        })
    }
}
