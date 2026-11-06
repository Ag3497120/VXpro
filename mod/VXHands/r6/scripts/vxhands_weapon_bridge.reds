// SPDX-License-Identifier: MIT
// The shipping 2.5.0 debug report entry consumes the string without writing a file.
// VXMac can receive these messages through its explicitly enabled native bridge.
@wrapMethod(SingleplayerMenuGameController)
protected cb func OnInitialize() -> Bool {
    let result = wrappedMethod();
    ResourceMetricsReportGenerator.WriteReportToFile("VXW1|B|equipment-and-shot");
    return result;
}

@addMethod(PlayerPuppet)
private func VXHandsPublishWeapon(weapon: wref<WeaponObject>, shot: Bool) {
    if !IsDefined(weapon) {
        ResourceMetricsReportGenerator.WriteReportToFile("VXW1|U");
        return;
    }
    let id = EntityID.ToDebugStringDecimal(weapon.GetEntityID());
    let record = ToString(TDBID.ToNumber(ItemID.GetTDBID(weapon.GetItemID())));
    if !shot {
        ResourceMetricsReportGenerator.WriteReportToFile("VXW1|E|" + id + "|" + record + (weapon.IsRanged() ? "|1" : "|0"));
        let kind = weapon.IsRanged() ? 2 : 0;
        if Equals(WeaponObject.GetWeaponType(weapon.GetItemID()), gamedataItemType.Wea_Handgun) { kind = 1; }
    if Equals(WeaponObject.GetWeaponType(weapon.GetItemID()), gamedataItemType.Wea_Revolver) { kind = 3; }
        ResourceMetricsReportGenerator.WriteReportToFile("VXW1|K|" + id + "|" + record + "|" + IntToString(kind));
        this.VXHandsReportReload(weapon);
        return;
    }
    let muzzle = weapon.GetMuzzleSlotWorldTransform();
    let p = Transform.GetPosition(muzzle);
    let f = Transform.GetForward(muzzle);
    ResourceMetricsReportGenerator.WriteReportToFile("VXW1|S|" + id + "|" + record
        + "|" + FloatToString(p.X) + "|" + FloatToString(p.Y) + "|" + FloatToString(p.Z)
        + "|" + FloatToString(f.X) + "|" + FloatToString(f.Y) + "|" + FloatToString(f.Z));
}

@wrapMethod(PlayerPuppet)
public final func UpdateWeaponRightEquippedItemInfo(slot: TweakDBID) {
    wrappedMethod(slot);
    if slot == t"AttachmentSlots.WeaponRight" && this == GetPlayer(this.GetGame()) {
        // Equipment updates occur after player input has been initialised.
        // Re-register here as game attach listeners can be cleared on load.
        this.RegisterInputListener(this, n"Reload");
        this.RegisterInputListener(this, n"VXHandsEject");
        this.RegisterInputListener(this, n"VXHandsInsert");
        this.RegisterInputListener(this, n"VXHandsChamber");
        this.VXHandsStartCommands();
        this.VXHandsProbePoseContexts();
        this.VXHandsPublishWeapon(this.VXHandsEquippedWeapon(), false);
    }
}

@wrapMethod(PlayerPuppet)
public final func OnItemUnequipped(slot: TweakDBID, item: ItemID) {
    wrappedMethod(slot, item);
    if slot == t"AttachmentSlots.WeaponRight" && this == GetPlayer(this.GetGame()) {
        let weapon = this.VXHandsEquippedWeapon();
        if IsDefined(weapon) && weapon.GetItemID() == item {
            weapon = null;
        }
        this.VXHandsPublishWeapon(weapon, false);
    }
}

@wrapMethod(ShootEvents)
protected final func OnEnter(stateContext: StateContext, scriptInterface: StateGameScriptInterface) {
    let player = scriptInterface.executionOwner as PlayerPuppet;
    if IsDefined(player) && player == GetPlayer(scriptInterface.GetGame()) {
        player.VXHandsObserveRightShot(scriptInterface.owner as WeaponObject);
    }
    wrappedMethod(stateContext, scriptInterface);
}

@addMethod(PlayerPuppet)
public final func VXHandsObserveRightShot(weapon: wref<WeaponObject>) {
    if IsDefined(weapon) && weapon == this.VXHandsEquippedWeapon() {
        this.VXHandsPublishWeapon(weapon, true);
    }
}
