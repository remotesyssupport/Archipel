/*
 * TNModule.j
 *
 * Copyright (C) 2010 Antoine Mercadal <antoine.mercadal@inframonde.eu>
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as
 * published by the Free Software Foundation, either version 3 of the
 * License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Affero General Public License for more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

@import <Foundation/Foundation.j>
@import <AppKit/AppKit.j>
@import <StropheCappuccino/StropheCappuccino.j>

@import "TNACP.j"

/*! @global
    @group TNModule
    the namespace of Archipel Push Notification stanzas.
*/
TNArchipelPushNotificationNamespace     = @"archipel:push";
TNArchipelPushNotificationPermissions   = @"archipel:push:permissions";

TNArchipelTypePermissions               = @"archipel:permissions";
TNArchipelTypePermissionsGet            = @"get";

TNArchipelErrorPermission               = 0;
TNArchipelErrorGeneral                  = 1;



/*! @ingroup archipelcore
    This is the root class of every module.
    All modules must inherit from TNModule.

    If the child class must perform custom operations on module events (see below),
    it *MUST* call the super method or the module can make all archipel unstable.

    Modules events are the following :
     - <b>willLoad</b>: This message is sent when module will be called by changing selection in roster. This assert than the module has its roster and entity properties sets.
     - <b>willUnload</b>: This message is sent when user change roster selection. It can be reloaded instant later, with another roster and entity.
     - <b>willShow</b>: This message is sent when user will display the GUI of the module.
     - <b>willHide</b>: This message is sent when user displays other module.
     - <b>menuReady</b>: This message is sent when the the Main Menu is ready. So if module wants to have a menu, it can implement it from its own _menu property
     - <b>savePreferences</b> this message is sent when user have change the preferences. If module has some, it must save them in the current default.
     - <b>loadPreferences</b> this message is sent when user call the preferences window. All modules prefs *MUST* be refreshed
     - <b>permissionsChanged</b> this message is sent when permissions of user has changed. This allow to updated GUI if needed

    A module can perform background task only if it is loaded. Loaded doesn't mean displayed on the screen. For example
    a statistic module can start collecting data on willLoad message in background. When message willShow is sent,
    module can perform operation to display the collected data in background and update this display. When willHide
    message is sent, module can stop to update the UI, but will continue to collect data. On willUnload message, the
    module *MUST* stop anything. willUnload will also remove all registration for this module. So if you have set some delegates
    (mostly CPTableView delegates) you *MUST* register them again on next willLoad. This avoid to use ressource for useless module.

    The root class willUnload will remove all TNStropheConnection handler, and remove the module from any subscription
    to CPNotification and all Archipel Push Notifications.

    You can use SampleTabModule and SampleToolbarModule to get example of module implémentation.

*/
@implementation TNModule : CPViewController
{
    @outlet CPView          viewPreferences             @accessors;

    BOOL                    _isActive                   @accessors(property=isActive, readonly);
    BOOL                    _isCurrentSelectedIndex     @accessors(getter=isCurrentSelectedIndex, setter=setCurrentSelectedIndex:);
    BOOL                    _isVisible                  @accessors(property=isVisible, readonly);
    BOOL                    _toolbarItemOnly            @accessors(getter=isToolbarItemOnly, setter=setToolbarItemOnly:);
    CPArray                 _mandatoryPermissions       @accessors(property=mandatoryPermissions);
    CPArray                 _supportedEntityTypes       @accessors(property=supportedEntityTypes);
    CPBundle                _bundle                     @accessors(property=bundle);
    CPMenu                  _menu                       @accessors(property=menu);
    CPMenuItem              _menuItem                   @accessors(property=menuItem);
    CPString                _label                      @accessors(property=label);
    CPString                _name                       @accessors(property=name);
    CPToolbar               _toolbar                    @accessors(property=toolbar);
    CPToolbarItem           _toolbarItem                @accessors(property=toolbarItem);
    CPView                  _viewPermissionsDenied      @accessors(getter=viewPermissionDenied);
    id                      _entity                     @accessors(property=entity);
    int                     _animationDuration          @accessors(property=animationDuration);
    int                     _index                      @accessors(property=index);
    TNStropheConnection     _connection                 @accessors(property=connection);
    TNStropheGroup          _group                      @accessors(property=group);
    TNStropheRoster         _roster                     @accessors(property=roster);

    BOOL                    _pubSubPermissionRegistred;
    CPArray                 _pubsubRegistrar;
    CPArray                 _registredSelectors;
    CPDictionary            _cachedGranted;
    CPDictionary            _cachedPermissions;
}


#pragma mark -
#pragma mark Initialization

- (id)init
{
    if (self = [super init])
    {
        _isActive               = NO;
        _isVisible              = NO;
        _pubsubRegistrar        = [CPArray array];
        _cachedGranted          = [CPDictionary dictionary];
    }
    return self;
}

/*! this method set the roster, the TNStropheConnection and the contact that module will be allow to access.
    YOU MUST NOT CALL THIS METHOD BY YOURSELF. TNModuleLoader will do the job for you.

    @param anEntity : TNStropheContact concerned by the module
    @param aConnection : TNStropheConnection general connection
    @param aRoster : TNStropheRoster general roster
*/
- (void)initializeWithEntity:(id)anEntity andRoster:(TNStropheRoster)aRoster
{
    _entity     = anEntity;
    _roster     = aRoster;
    _connection = [_roster connection];
}


#pragma mark -
#pragma mark Setters and Getters

/*! @ignore
    we need to archive and unarchive to get a proper copy of the view
*/
- (void)setViewPermissionDenied:(CPView)aView
{
    var data = [CPKeyedArchiver archivedDataWithRootObject:aView];

    _viewPermissionsDenied = [CPKeyedUnarchiver unarchiveObjectWithData:data];
}


#pragma mark -
#pragma mark Events management

/*! @ignore
    this message is called when a matching pubsub event is received
    @param aStanza the TNStropheStanza that contains the event
    @return YES in order to continue to listen for events
*/
- (void)_onPubSubEvents:(TNStropheStanza)aStanza
{
    CPLog.trace("Raw (not filtered) pubsub event received from " + [aStanza from]);

    var nodeOwner   = [[aStanza firstChildWithName:@"items"] valueForAttribute:@"node"].split("/")[2],
        pushType    = [[aStanza firstChildWithName:@"push"] valueForAttribute:@"xmlns"],
        pushDate    = [[aStanza firstChildWithName:@"push"] valueForAttribute:@"date"],
        pushChange  = [[aStanza firstChildWithName:@"push"] valueForAttribute:@"change"],
        infoDict    = [CPDictionary dictionaryWithObjectsAndKeys:   nodeOwner,  @"owner",
                                                                    pushType,   @"type",
                                                                    pushDate,   @"date",
                                                                    pushChange, @"change"];

    for (var i = 0; i < [_pubsubRegistrar count]; i++)
    {
        var item = [_pubsubRegistrar objectAtIndex:i];

        if (pushType == [item objectForKey:@"type"])
        {
            [self performSelector:[item objectForKey:@"selector"] withObject:infoDict]
        }
    }

    return YES;
}

/*! @ignore
    This method allow the module to register itself to Archipel Push notification (archipel:push namespace)

    A valid Archipel Push is following the form:
    <message from="pubsub.xmppserver" type="headline" to="controller@xmppserver" >
        <event xmlns="http://jabber.org/protocol/pubsub#event">
            <items node="/archipel/09c206aa-8829-11df-aa46-0016d4e6adab@xmppserver/events" >
                <item id="DEADBEEF" >
                    <push xmlns="archipel:push:disk" date="1984-08-18 09:42:00.00000" change="created" />
                </item>
            </items>
        </event>
    </message>

    @param aSelector: Selector to perform on recieve of archipel:push with given type
    @param aPushType: CPString of the push type that will trigger the selector.
*/
- (void)registerSelector:(SEL)aSelector forPushNotificationType:(CPString)aPushType
{
    if ([_entity class] == TNStropheContact)
    {
        var registrarItem = [CPDictionary dictionary];

        CPLog.info([self class] + @" is registring for push notification of type : " + aPushType);
        [registrarItem setValue:aSelector forKey:@"selector"];
        [registrarItem setValue:aPushType forKey:@"type"];

        [_pubsubRegistrar addObject:registrarItem];
    }
}

/*! @ignore
    this message is sent when module receive a permission push in order to refresh
    display and permission cache
    @param somePushInfo the push informations as a CPDictionary
*/
- (BOOL)_onPermissionsPubSubEvents:(TNStropheStanza)aStanza
{
    var sender  = [[aStanza firstChildWithName:@"items"] valueForAttribute:@"node"].split("/")[2],
        type    = [[aStanza firstChildWithName:@"push"] valueForAttribute:@"xmlns"],
        change  = [[aStanza firstChildWithName:@"push"] valueForAttribute:@"change"];

    if (type != TNArchipelPushNotificationPermissions)
        return YES // continue to listen event;

    // check if we already have cached some information about the entity
    // if not, permissions will be recovered at next display so we don't care
    if ([_cachedGranted containsKey:sender])
    {
        var anEntity = [_roster contactWithBareJID:[TNStropheJID stropheJIDWithString:sender]];

        // invalidate the cache for current entity
        [_cachedGranted removeObjectForKey:sender];
        CPLog.info("cache for module " + _label + " and entity " + anEntity + " has been invalidated");

        // if the sender if the _entity then we'll need to perform graphicall chages
        // otherwise we just update the cache.
        if (anEntity === _entity)
        {
            [self _checkMandatoryPermissionsAndPerformOnGrant:@selector(_managePermissionGranted) onDenial:@selector(_managePermissionDenied) forEntity:anEntity];
        }
        else
            [self _checkMandatoryPermissionsAndPerformOnGrant:nil onDenial:nil forEntity:anEntity];
    }

    return YES;
}


#pragma mark -
#pragma mark Mandatory permissions caching

/*! @ignore
    Check if given entity meet the minimal mandatory permission to display the module
    Thoses mandatory permissions are stored into _mandatoryPermissions
    @param grantedSelector selector that will be executed if user is conform to mandatory permissions
    @param grantedSelector selector that will be executed if user is not conform to mandatory permissions
    @param anEntity the entity to which we should check the permission
*/
- (void)_checkMandatoryPermissionsAndPerformOnGrant:(SEL)grantedSelector onDenial:(SEL)denialSelector forEntity:(TNStropheContact)anEntity
{
    if (!anEntity)
        return;

    if (!_cachedGranted)
        _cachedGranted = [CPDictionary dictionary];

    if (!_cachedPermissions)
        _cachedPermissions = [CPDictionary dictionary];

    if (!_mandatoryPermissions || [_mandatoryPermissions count] == 0)
    {
        if (grantedSelector)
            [self performSelector:grantedSelector];

        return;
    }

    if ([_cachedGranted containsKey:[[anEntity JID] bare]])
    {
        CPLog.info("recover permission from cache for module " + _label + " and entity" + anEntity);
        if ([self isEntityGranted:anEntity] && grantedSelector)
            [self performSelector:grantedSelector];
        else if (denialSelector)
            [self performSelector:denialSelector];

        return;
    }

    CPLog.info("Ask permission to entity for module " + _label + " and entity" + anEntity);

    var stanza = [TNStropheStanza iqWithType:@"get"],
        selectors = [CPDictionary dictionaryWithObjectsAndKeys: grantedSelector, @"grantedSelector",
                                                                denialSelector, @"denialSelector",
                                                                anEntity, @"entity"];

    [stanza addChildWithName:@"query" andAttributes:{"xmlns": TNArchipelTypePermissions}];
    [stanza addChildWithName:@"archipel" andAttributes:{
        "action": TNArchipelTypePermissionsGet,
        "permission_type": "user",
        "permission_target": [[_connection JID] bare]}];

    [anEntity sendStanza:stanza andRegisterSelector:@selector(_didReceiveMandatoryPermissions:selectors:) ofObject:self userInfo:selectors];
}

/*! @ignore
    compute the answer containing the users' permissions
    @param aStanza TNStropheStanza containing the answer
    @param someUserInfo CPDictionary containing the two selectors and the current entity
*/
- (void)_didReceiveMandatoryPermissions:(TNStropheStanza)aStanza selectors:(CPDictionary)someUserInfo
{
    if ([aStanza type] == @"result")
    {
        var permissions         = [aStanza childrenWithName:@"permission"],
            anEntity            = [someUserInfo objectForKey:@"entity"],
            defaultAdminAccount = [[CPBundle mainBundle] objectForInfoDictionaryKey:@"ArchipelDefaultAdminAccount"];

        [_cachedPermissions setObject:[CPArray array] forKey:[[anEntity JID] bare]];
        [_cachedGranted setValue:YES forKey:[[anEntity JID] bare]];

        for (var i = 0; i < [permissions count]; i++)
        {
            var permission      = [permissions objectAtIndex:i],
                name            = [permission valueForAttribute:@"name"];

            [[_cachedPermissions objectForKey:[[anEntity JID] bare]] addObject:name];
        }

        if ((![[_cachedPermissions objectForKey:[[anEntity JID] bare]] containsObject:@"all"])
            && [[_connection JID] bare] != defaultAdminAccount)
        {
            for (var i = 0; i < [_mandatoryPermissions count]; i++)
            {
                if (![[_cachedPermissions objectForKey:[[anEntity JID] bare]] containsObject:[_mandatoryPermissions objectAtIndex:i]])
                {
                    [_cachedGranted setValue:NO forKey:[[anEntity JID] bare]];
                    break;
                }
            }
        }

        if ([self isEntityGranted:anEntity] && [someUserInfo objectForKey:@"grantedSelector"])
            [self performSelector:[someUserInfo objectForKey:@"grantedSelector"]];
        else if ([someUserInfo objectForKey:@"denialSelector"])
            [self performSelector:[someUserInfo objectForKey:@"denialSelector"]];

        CPLog.info("Permissions for module " + _label + " and entity" + anEntity + " sucessfully cached");
        [self permissionsChanged];
    }
    else
    {
        [self handleIqErrorFromStanza:aStanza]
    }
}

/*! @ignore
    Display the permission denial view
*/
- (void)_managePermissionGranted
{
    if (!_isActive)
        [self willLoad];

    if (!_isVisible && _isCurrentSelectedIndex)
        [self willShow];

    [self _hidePermissionDeniedView];
}

/*! @ignore
    Hide the permission denial view
*/
- (void)_managePermissionDenied
{
    if (_isVisible)
        [self willHide];

    if (_isActive)
        [self willUnload];

    [self _showPermissionDeniedView];
}

/*! @ignore
    show the permission denied view
*/
- (void)_showPermissionDeniedView
{
    if ([_viewPermissionsDenied superview])
        return;

    [_viewPermissionsDenied setFrame:[[self view] frame]];
    [[self view] addSubview:_viewPermissionsDenied];
}

/*! @ignore
    hide the permission denied view
*/
- (void)_hidePermissionDeniedView
{
    if ([_viewPermissionsDenied superview])
        [_viewPermissionsDenied removeFromSuperview];
}

/*! @ignore
    This is called my module controller in order to check if user is granted to display module
    it will check from cache if any cahed value, or will ask entity with ACP permissions 'get'
*/
- (void)_beforeWillLoad
{
    if (!_pubSubPermissionRegistred)
    {
        [TNPubSubNode registerSelector:@selector(_onPermissionsPubSubEvents:) ofObject:self forPubSubEventWithConnection:_connection];
        _pubSubPermissionRegistred = YES;
    }

    [self _checkMandatoryPermissionsAndPerformOnGrant:@selector(_managePermissionGranted) onDenial:@selector(_managePermissionDenied) forEntity:_entity];
}


#pragma mark -
#pragma mark Permissions interface

/*! check if given entity is granted to display this module
    @param anEntity the entity to check
    @return YES if anEntity is granted, NO otherwise
*/
- (BOOL)isEntityGranted:(TNStropheContact)anEntity
{
    if ([anEntity class] !== TNStropheContact)
        return NO;

    if ([[_connection JID] bare] === [[CPBundle mainBundle] objectForInfoDictionaryKey:@"ArchipelDefaultAdminAccount"])
        return YES;

    return [_cachedGranted valueForKey:[[anEntity JID] bare]];
}

/*! check if current is granted to display this module
    @return YES if anEntity is granted, NO otherwise
*/
- (BOOL)isCurrentEntityGranted
{
    return [self isEntityGranted:_entity];
}

/*! check if given entity has given permission
    @param anEntity the entity to check
    @return YES if anEntity has permission, NO otherwise
*/
- (BOOL)entity:(TNStropheContact)anEntity hasPermission:(CPString)aPermission
{
    if ([anEntity class] !== TNStropheContact)
        return NO;

    if ([[_connection JID] bare] === [[CPBundle mainBundle] objectForInfoDictionaryKey:@"ArchipelDefaultAdminAccount"])
        return YES;

    if ([[_cachedPermissions objectForKey:[[anEntity JID] bare]] containsObject:@"all"])
        return YES;

    return [[_cachedPermissions objectForKey:[[anEntity JID] bare]] containsObject:aPermission];
}

/*! check if current entity has given permission
    @return YES if anEntity has permission, NO otherwise
*/
- (BOOL)currentEntityHasPermission:(CPString)aPermission
{
    return [self entity:_entity hasPermission:aPermission];
}

/*! check if given entity has all permissions given in permissionsList
    @param anEntity the entity to check
    @return YES if anEntity has all permissions, NO otherwise
*/
- (BOOL)entity:(TNStropheContact)anEntity hasPermissions:(CPArray)permissionsList
{
    var ret = YES;
    for (var i = 0; i < [permissionsList count]; i++)
        ret = ret && [self entity:anEntity hasPermission:[permissionsList objectAtIndex:i]];

    return ret;
}

/*! check if current entity has all permissions given in permissionsList
    @return YES if anEntity has permission, NO otherwise
*/
- (BOOL)currentEntityHasPermissions:(CPArray)permissionsList
{
    return [self entity:_entity hasPermissions:permissionsList];
}


#pragma mark -
#pragma mark TNModule events implementation

/*! This message is sent when module is loaded. It will
    reinitialize the _registredSelectors dictionary
*/
- (void)willLoad
{
    [self _hidePermissionDeniedView];

    _animationDuration  = [[CPBundle mainBundle] objectForInfoDictionaryKey:@"TNArchipelAnimationsDuration"]; // if I put this in init, it won't work.
    _isActive           = YES;
    _registredSelectors = [CPArray array];
    _pubsubRegistrar    = [CPArray array];

    [_registredSelectors addObject:[TNPubSubNode registerSelector:@selector(_onPubSubEvents:) ofObject:self forPubSubEventWithConnection:_connection]];

    [_menuItem setEnabled:YES];

}

/*! This message is sent when module is unloaded. It will remove all push registration,
    all TNStropheConnection registration and all CPNotification subscription
*/
- (void)willUnload
{
    // remove all notification observers
    [[CPNotificationCenter defaultCenter] removeObserver:self];

    // unregister all selectors
    for (var i = 0; i < [_registredSelectors count]; i++)
    {
        CPLog.trace("deleting SELECTOR in  " + _label + " :" + [_registredSelectors objectAtIndex:i]);
        [_connection deleteRegisteredSelector:[_registredSelectors objectAtIndex:i]];
    }

    // flush any outgoing stanza
    [_connection flush];

    [_pubsubRegistrar removeAllObjects];
    [_registredSelectors removeAllObjects];

    [_menuItem setEnabled:NO];

    _isActive = NO;
}

/*! This message is sent when module will be displayed
    @return YES if all permission are granted
*/
- (BOOL)willShow
{
    if (![self isCurrentEntityGranted])
        return NO;

    var defaults = [CPUserDefaults standardUserDefaults];

    if ([defaults boolForKey:@"TNArchipelUseAnimations"])
    {
        var animView    = [CPDictionary dictionaryWithObjectsAndKeys:[self view], CPViewAnimationTargetKey, CPViewAnimationFadeInEffect, CPViewAnimationEffectKey],
            anim        = [[CPViewAnimation alloc] initWithViewAnimations:[animView]];

        [anim setDuration:_animationDuration];
        [anim startAnimation];
    }
    _isVisible = YES;

    return YES;
}

/*! this message is sent when user click on another module.
*/
- (void)willHide
{
    _isVisible = NO;
}

/*! this message is sent when the MainMenu is ready
    i.e. you can insert your module menu items;
*/
- (void)menuReady
{
    // executed when menu is ready
}

/*! this message is sent when the user changes the preferences. Implement this method to store
    datas from your eventual viewPreferences
*/
- (void)savePreferences
{
    // executed when use saves preferences
}

/*! this message is sent when Archipel displays the preferences window.
    implement this in order to refresh your eventual viewPreferences
*/
- (void)loadPreferences
{
    // executed when archipel displays preferences panel
}

/*! this message is sent when user permission changes
    this allow modules to update interfaces according to permissions
*/
- (void)permissionsChanged
{
    // called when permissions changes
}

/*! this message is sent only in case of a ToolbarItem module when user
    press the module's toolbar icon.
*/
- (IBAction)toolbarItemClicked:(id)sender
{
    // executed when users click toolbar item in case of toolbar module
}


#pragma mark -
#pragma mark Communication utilities

/*! this message simplify the sending and the post-management of TNStropheStanza to the contact
    @param aStanza: TNStropheStanza to send to the contact
    @param aSelector: Selector to perform when contact send answer
*/
- (void)sendStanza:(TNStropheStanza)aStanza andRegisterSelector:(SEL)aSelector
{
    var selectorID = [_entity sendStanza:aStanza andRegisterSelector:aSelector ofObject:self];
    [_registredSelectors addObject:selectorID];
}

/*! this message simplify the sending and the post-management of TNStropheStanza to the contact
    if also allow to define the XMPP uid of the stanza. This is useless in the most of case.
    @param aStanza: TNStropheStanza to send to the contact
    @param aSelector: Selector to perform when contact send answer
    @param anUid: CPString containing the XMPP uid to use.
*/
- (void)sendStanza:(TNStropheStanza)aStanza andRegisterSelector:(SEL)aSelector withSpecificID:(CPString)anUid
{
    var selectorID = [_entity sendStanza:aStanza andRegisterSelector:aSelector ofObject:self withSpecificID:anUid];
    [_registredSelectors addObject:selectorID];
}

/*! This message allow to display an error when stanza type is error
    @param aStanza the stanza containing the error
*/
- (void)handleIqErrorFromStanza:(TNStropheStanza)aStanza
{
    var growl   = [TNGrowlCenter defaultCenter],
        code    = [[aStanza firstChildWithName:@"error"] valueForAttribute:@"code"],
        type    = [[aStanza firstChildWithName:@"error"] valueForAttribute:@"type"],
        perm    = [[aStanza firstChildWithName:@"error"] firstChildWithName:@"archipel-error-permission"];

    if (perm)
    {
        CPLog.warn("Permission denied (" + code + "): " + [[aStanza firstChildWithName:@"text"] text]);
        msg = [[aStanza firstChildWithName:@"text"] text];
        [growl pushNotificationWithTitle:@"Permission denied" message:msg icon:TNGrowlIconWarning];
        return TNArchipelErrorPermission
    }
    else if ([aStanza firstChildWithName:@"text"])
    {
        var msg     = [[aStanza firstChildWithName:@"text"] text];

        [growl pushNotificationWithTitle:@"Error (" + code + " / " + type + ")" message:msg icon:TNGrowlIconError];
        CPLog.error(msg);
    }
    else
        CPLog.error(@"Error " + code + " / " + type + ". No message. If 503, it should be allright");

    return TNArchipelErrorGeneral;
}

@end