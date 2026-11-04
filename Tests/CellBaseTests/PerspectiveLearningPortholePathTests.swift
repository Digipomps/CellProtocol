// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import CellBase
@testable import CellApple

/// Explicit native load/rollback witnesses only. This is not learned autonomous routing.
final class PerspectiveLearningPortholePathTests: XCTestCase {
 @MainActor
 func testExplicitNativeLoadUpdatesOrchestratorAndViewModelIdentity() async throws {
  let oldVault=CellBase.defaultIdentityVault;let oldResolver=CellBase.defaultCellResolver
  defer { CellBase.defaultIdentityVault=oldVault;CellBase.defaultCellResolver=oldResolver }
  let vault=MockIdentityVault();CellBase.defaultIdentityVault=vault;CellBase.defaultCellResolver=CellResolver.sharedInstance
  let found=await vault.identity(for:"perspective-path-owner-"+UUID().uuidString,makeNewIfNotFound:true)
  let owner=try XCTUnwrap(found);let cell=await OrchestratorCell(owner:owner)
  let name="synthetic-config-"+UUID().uuidString
  let config=CellConfiguration(name:name,cellReferences:[])
  let result=try await cell.set(keypath:"setConfiguration",value:.cellConfiguration(config),requester:owner)
  guard case .string("ok")?=result else { return XCTFail("Explicit native configuration was not acknowledged") }
  XCTAssertEqual(cell.getCellConfiguration()?.name,name)
  let model=PortholeViewModel();await model.initializationTask?.value
  model.applyCellConfiguration(cellConfiguration:config)
  XCTAssertEqual(model.currentConfigurationName,name)
  // View-model state is not a rendered UI/client receipt or an autonomous learning path.
 }
 func testFailedNativeLoadPreservesPreviousConfiguration() async throws {
  let oldVault=CellBase.defaultIdentityVault;let oldResolver=CellBase.defaultCellResolver
  defer { CellBase.defaultIdentityVault=oldVault;CellBase.defaultCellResolver=oldResolver }
  let vault=MockIdentityVault();CellBase.defaultIdentityVault=vault;CellBase.defaultCellResolver=CellResolver.sharedInstance
  let found=await vault.identity(for:"perspective-rollback-owner-"+UUID().uuidString,makeNewIfNotFound:true)
  let owner=try XCTUnwrap(found);let cell=await OrchestratorCell(owner:owner)
  let before=CellConfiguration(name:"synthetic-before-"+UUID().uuidString,cellReferences:[])
  try await cell.loadCellConfiguration(before,requester:owner)
  CellBase.defaultCellResolver=nil
  do {
   try await cell.loadCellConfiguration(CellConfiguration(name:"must-not-be-acknowledged",cellReferences:[]),requester:owner)
   XCTFail("Expected missing resolver to reject actual load")
  } catch { XCTAssertEqual(cell.getCellConfiguration()?.name,before.name) }
 }
}
