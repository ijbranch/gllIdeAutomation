(*
  gllIdeAutomation - reading what a virtual tree displays

  Copyright (c) 2016-2026 Ian Branch (GITLAK Software)
  Licensed under the MIT Licence - see LICENSE at the root of this repository.

  CREDIT: the technique is Thomas Mueller's, from the TREETEXT command of GxInspect, the GExperts
  UI inspection server (host/GxInspect_Server.pas, GExperts ^/GxInspect/trunk, September 2026).
  This is a re-implementation in this package's style, not a copy: the same idea - stand in front
  of OnGetText, make the control paint, write down what the real handler answers - plus a check of
  the event's signature against RTTI before hooking it, per-row node levels, header captions, and
  a row limit.

  FORK: this unit exists only in gllIdeAutomation. GITLAKLib's gllAutomationServer has no use for
  it - no DBiWorkflow form carries a virtual tree - so there is nothing to carry back.
*)
/// <summary>
///   Reads the text a <c>TVirtualStringTree</c> displays, from outside the module that owns it. Such
///   a tree holds no text of its own: its <c>OnGetText</c> handler is asked for each cell as it
///   paints, with node pointers nothing outside the tree can make up. So the reader puts a handler
///   of the same signature in front of the event, walks the control a page at a time so every row
///   paints, records what the original handler answered, and puts it back. This is what makes the
///   IDE's Local Variables, Watch and Call Stack panes readable.
/// </summary>
unit gllIdeAutomation.TreeText;

interface

uses
  System.SysUtils, Vcl.Controls;

const
  /// <summary>Row limit applied when the caller does not give one.</summary>
  TREE_TEXT_DEFAULT_MAX_ROWS = 2000;
  /// <summary>Largest row limit accepted; a larger request is clamped to this.</summary>
  TREE_TEXT_MAX_ROWS_LIMIT   = 100000;

type
  /// <summary>
  ///   The reader declined to read a control, for a reason the caller can act on. <c>Code</c> is a
  ///   stable machine-readable reason, surfaced by the server as <c>error.code</c>.
  /// </summary>
  ETreeTextRefused = class( Exception )
  public
    /// <summary>
    ///   The stable reason: <c>NotVirtualTree</c>, <c>NoWindow</c>, <c>NotOnScreen</c>,
    ///   <c>NoGetText</c> or <c>SignatureMismatch</c>.
    /// </summary>
    Code: string;
    /// <summary>Creates the refusal with its reason code and a human-readable message.</summary>
    /// <param name="ACode">The stable reason code.</param>
    /// <param name="AMsg">The message, which says how to get past the refusal where there is a way.</param>
    constructor CreateCode( const ACode, AMsg: string );
  end;

  /// <summary>One displayed row of a virtual tree.</summary>
  TTreeTextRow = record
    /// <summary>
    ///   Nesting depth, 0 for a top-level node; -1 when the tree's <c>GetNodeLevel</c> could not be
    ///   reached through RTTI.
    /// </summary>
    Level: Integer;
    /// <summary>
    ///   Cell text by column INDEX (not display position), with trailing empty cells removed. A tree
    ///   with no header columns yields one cell.
    /// </summary>
    Cells: TArray<string>;
  end;

  /// <summary>Everything one read of a virtual tree produced.</summary>
  TTreeTextResult = record
    /// <summary>The rows in display order, top to bottom, each node once.</summary>
    Rows: TArray<TTreeTextRow>;
    /// <summary>Header captions by column index; empty when the tree has no header columns.</summary>
    Columns: TArray<string>;
    /// <summary>The tree's own count of top-level nodes, or -1 when it does not publish one.</summary>
    RootCount: Integer;
    /// <summary>
    ///   True when the walk reached the bottom, no limit cut it short, and at least
    ///   <c>RootCount</c> rows were read. A partial read is never presented as complete.
    /// </summary>
    Complete: Boolean;
    /// <summary>Anything the caller should know about how the rows were obtained.</summary>
    Notes: TArray<string>;
  end;

/// <summary>
///   Whether an object is a virtual tree, judged by class NAME up its ancestry. <c>is</c> cannot be
///   used: the tree's classes live in the host's own VirtualTrees module, not in anything this
///   package links.
/// </summary>
/// <param name="AObj">The object to test; may be nil.</param>
/// <returns>True for a <c>TBaseVirtualTree</c> or <c>TCustomVirtualStringTree</c> descendant.</returns>
function IsVirtualTree( AObj: TObject ): Boolean;

/// <summary>
///   Reads every displayed row of a virtual tree. Collapsed children are not displayed and so are
///   not read. The control scrolls visibly while it is read, and is returned to the scroll position
///   it had.
/// </summary>
/// <param name="AControl">The tree. It must have a window, and that window must be on screen.</param>
/// <param name="AMaxRows">Stop after this many rows; clamped to 1..<c>TREE_TEXT_MAX_ROWS_LIMIT</c>.</param>
/// <returns>The rows, the header captions, and whether the read was complete.</returns>
/// <exception cref="ETreeTextRefused">
///   The control cannot be read: not a virtual tree, no window, not on screen, no
///   <c>OnGetText</c> handler, or a handler whose signature does not match the one this reader
///   stands in for. Nothing is hooked when this is raised.
/// </exception>
/// <remarks>Must run on the thread that owns the control's window: it sends paint and scroll messages.</remarks>
function ReadTreeText( AControl: TControl; AMaxRows: Integer ): TTreeTextResult;

implementation

uses
  System.Classes, System.TypInfo, System.Rtti, System.Generics.Collections,
  Winapi.Windows, Winapi.Messages;

type
  /// <summary>
  ///   The shape of <c>TVSTGetTextEvent</c> where the cell text is a <c>var string</c>, as current
  ///   VirtualTrees declares it. Declared here because VirtualTrees is not a unit this package may
  ///   use - and would be a different class from the host's if it did. Only the shape has to match,
  ///   which <c>SignatureMismatch</c> confirms from RTTI before anything is hooked: Sender is an
  ///   object, Node a <c>PVirtualNode</c>, Column a 4-byte <c>TColumnIndex</c>, TextType a
  ///   byte-sized <c>TVSTTextType</c>.
  /// </summary>
  TVstGetTextEventStr = procedure( ASender: TObject; ANode: Pointer; AColumn: Integer; ATextType: Byte;
    var ACellText: string ) of object;

  /// <summary>
  ///   The same event with the cell text a <c>var WideString</c> - the shape the Delphi 13 IDE's own
  ///   VirtualTrees uses, measured 2026-09-25 on all three debugger panes of the 64-bit IDE.
  ///   Every IDE declares it this way, 32-bit included (Thomas Mueller, GxInspect r5813): the IDE
  ///   ships an older VirtualTrees of its own, <c>Idevirtualtrees</c> in <c>vclide&lt;ver&gt;.bpl</c>.
  ///   A <c>WideString</c> is a COM BSTR and a <c>string</c> is a reference-counted UnicodeString;
  ///   the characters coincide but the headers do not, so reading one as the other gets the length
  ///   wrong and writes a reference count into memory that is not a string header.
  /// </summary>
  TVstGetTextEventWide = procedure( ASender: TObject; ANode: Pointer; AColumn: Integer; ATextType: Byte;
    var ACellText: WideString ) of object;

  /// <summary>
  ///   Stands in front of one tree's <c>OnGetText</c> for the length of one read, collecting what the
  ///   real handler answers, keyed on the node so repeated paints of a row merge into one entry.
  /// </summary>
  TTreeTextReader = class
  private
    /// <summary>The tree being read.</summary>
    FTree: TWinControl;
    /// <summary>The tree's <c>OnGetText</c> property; nil once the original handler is back.</summary>
    FPropInfo: PPropInfo;
    /// <summary>The handler that was assigned before this reader took its place.</summary>
    FOriginal: TMethod;
    /// <summary>The handler this reader installed, to recognise it when putting the original back.</summary>
    FMine: TMethod;
    /// <summary>True when the tree's cell text is a <c>WideString</c>; selects which shape to install and call.</summary>
    FWide: Boolean;
    /// <summary>Set when something else replaced this reader's handler while it was installed.</summary>
    FDisplaced: Boolean;
    /// <summary>The first failure inside the handler, where it could not be raised.</summary>
    FFailure: string;
    /// <summary>Row index for each node already seen.</summary>
    FRowOf: TDictionary<Pointer, Integer>;
    /// <summary>Cell texts by column index, one list per row, in the order rows were first painted.</summary>
    FCells: TObjectList<TStringList>;
    /// <summary>Nesting depth per row, parallel to <c>FCells</c>; -1 where it could not be read.</summary>
    FLevels: TList<Integer>;
    /// <summary>RTTI context kept alive for <c>FLevelMethod</c>.</summary>
    FContext: TRttiContext;
    /// <summary>The tree's <c>GetNodeLevel</c>, or nil when RTTI does not offer a usable one.</summary>
    FLevelMethod: TRttiMethod;
    /// <summary>The type of <c>GetNodeLevel</c>'s node parameter, needed to build its argument.</summary>
    FLevelParamType: PTypeInfo;
    /// <summary>Set when calling <c>GetNodeLevel</c> failed once, so it is not tried again.</summary>
    FLevelFailed: Boolean;
    /// <summary>Stand-in for a <c>string</c>-shaped <c>OnGetText</c>: calls the original, then records its answer.</summary>
    /// <param name="ASender">The tree.</param>
    /// <param name="ANode">The node being painted.</param>
    /// <param name="AColumn">The column index; -1 on a tree without header columns.</param>
    /// <param name="ATextType">0 for a cell's normal text; other values are the static text beside it.</param>
    /// <param name="ACellText">The text, as the original handler left it.</param>
    procedure HandleGetTextStr( ASender: TObject; ANode: Pointer; AColumn: Integer; ATextType: Byte;
      var ACellText: string );
    /// <summary>Stand-in for a <c>WideString</c>-shaped <c>OnGetText</c>: calls the original, then records its answer.</summary>
    /// <param name="ASender">The tree.</param>
    /// <param name="ANode">The node being painted.</param>
    /// <param name="AColumn">The column index; -1 on a tree without header columns.</param>
    /// <param name="ATextType">0 for a cell's normal text; other values are the static text beside it.</param>
    /// <param name="ACellText">The text, as the original handler left it.</param>
    procedure HandleGetTextWide( ASender: TObject; ANode: Pointer; AColumn: Integer; ATextType: Byte;
      var ACellText: WideString );
    /// <summary>Records one cell's text against its node and column; never raises.</summary>
    /// <param name="ANode">The node being painted.</param>
    /// <param name="AColumn">The column index; -1 on a tree without header columns.</param>
    /// <param name="ATextType">0 for a cell's normal text; anything else is ignored.</param>
    /// <param name="AText">The text the original handler produced, already converted to <c>string</c>.</param>
    procedure RecordCell( ANode: Pointer; AColumn: Integer; ATextType: Byte; const AText: string );
    /// <summary>The nesting depth of a node, through the tree's own <c>GetNodeLevel</c>.</summary>
    /// <param name="ANode">A node the tree is painting, and therefore a live one.</param>
    /// <returns>The depth, or -1 when it cannot be read.</returns>
    function NodeLevel( ANode: Pointer ): Integer;
    /// <summary>Finds the tree's <c>GetNodeLevel</c> through RTTI, leaving <c>FLevelMethod</c> nil if unusable.</summary>
    procedure FindLevelMethod;
    /// <summary>Whether the event still holds this reader's handler.</summary>
    /// <returns>True when nothing has replaced it.</returns>
    function StillMine: Boolean;
    /// <summary>Puts the original handler back; harmless to call twice.</summary>
    procedure Uninstall;
  public
    /// <summary>Installs the reader in front of the tree's current <c>OnGetText</c> handler.</summary>
    /// <param name="ATree">The tree to read.</param>
    /// <param name="APropInfo">The tree's <c>OnGetText</c> property, already signature-checked.</param>
    /// <param name="AWide">True when that check found the cell text to be a <c>WideString</c>.</param>
    constructor Create( ATree: TWinControl; APropInfo: PPropInfo; AWide: Boolean );
    /// <summary>Puts the original handler back if it is not back already, and frees the rows.</summary>
    destructor Destroy; override;
    /// <summary>
    ///   Scrolls the tree from top to bottom a page at a time, painting each page, then returns it to
    ///   where it was and uninstalls the reader.
    /// </summary>
    /// <param name="AMaxRows">Stop once this many rows have been collected.</param>
    /// <returns>True when the walk reached the bottom rather than stopping at a limit.</returns>
    function Walk( AMaxRows: Integer ): Boolean;
    /// <summary>Copies the collected rows out, in display order.</summary>
    /// <returns>One entry per row.</returns>
    function Rows: TArray<TTreeTextRow>;
    /// <summary>True if something replaced the handler while it was installed.</summary>
    property Displaced: Boolean read FDisplaced;
    /// <summary>Empty unless a cell could not be recorded.</summary>
    property Failure: string read FFailure;
    /// <summary>True when node levels could not be read and every row reports -1.</summary>
    /// <returns>True when the tree offers no usable <c>GetNodeLevel</c>, or calling it failed.</returns>
    function LevelsUnavailable: Boolean;
  end;

const
  /// <summary><c>TVSTTextType.ttNormal</c>: a cell's own text, as opposed to the static text beside it.</summary>
  VST_TEXT_NORMAL = 0;
  /// <summary>Scroll steps before a walk is abandoned, so a tree that never stops scrolling cannot hang the IDE.</summary>
  WALK_MAX_STEPS  = 1000;

{ ── ETreeTextRefused ───────────────────────────────────────────────────── }

constructor ETreeTextRefused.CreateCode( const ACode, AMsg: string );
begin

  inherited Create( AMsg );
  Code := ACode;

end;

{ ── helpers ────────────────────────────────────────────────────────────── }

function IsVirtualTree( AObj: TObject ): Boolean;
begin

  if AObj = nil then Exit( False );

  var oClass := AObj.ClassType;
  while Assigned( oClass ) do
  begin
    if oClass.ClassNameIs( 'TBaseVirtualTree' ) or oClass.ClassNameIs( 'TCustomVirtualStringTree' ) then
      Exit( True );
    oClass := oClass.ClassParent;
  end;

  Result := False;

end;

/// <summary>
///   Compares the tree's <c>OnGetText</c> type, read from RTTI, with <c>TVstGetTextEventStr</c> and
///   <c>TVstGetTextEventWide</c>. A mismatch that went unnoticed would not be a compile error but
///   corrupted text or an access violation inside the host's paint, so the reader refuses rather
///   than hope - which is exactly what caught the IDE's <c>WideString</c> on 2026-09-25, before the
///   reader accepted that shape.
/// </summary>
/// <param name="APropInfo">The tree's <c>OnGetText</c> property.</param>
/// <param name="AWide">Set to True when the cell text is a <c>WideString</c>, False for <c>string</c>.</param>
/// <returns>Empty when one of the shapes matches; otherwise the event's actual declaration, for the message.</returns>
function SignatureMismatch( APropInfo: PPropInfo; out AWide: Boolean ): string;
begin

  AWide := False;

  var oContext := TRttiContext.Create;
  try
    var oType := oContext.GetType( APropInfo^.PropType^ );
    if not ( oType is TRttiMethodType ) then
      Exit( 'OnGetText is not a method type' );

    var oMethType := TRttiMethodType( oType );
    Result := oMethType.ToString;

    if ( oMethType.MethodKind <> mkProcedure ) or ( oMethType.CallingConvention <> ccReg ) then Exit;

    var aParams := oMethType.GetParameters;
    if Length( aParams ) <> 5 then Exit;
    for var oParam in aParams do
      if oParam.ParamType = nil then Exit;

    if aParams[ 0 ].ParamType.TypeKind <> tkClass then Exit;
    if aParams[ 1 ].ParamType.TypeKind <> tkPointer then Exit;
    if ( aParams[ 2 ].ParamType.TypeKind <> tkInteger ) or ( aParams[ 2 ].ParamType.TypeSize <> SizeOf( Integer ) ) then Exit;
    if ( aParams[ 3 ].ParamType.TypeKind <> tkEnumeration ) or ( aParams[ 3 ].ParamType.TypeSize <> SizeOf( Byte ) ) then Exit;
    if not ( pfVar in aParams[ 4 ].Flags ) then Exit;
    if not ( aParams[ 4 ].ParamType.TypeKind in [ tkUString, tkWString ] ) then Exit;

    AWide  := aParams[ 4 ].ParamType.TypeKind = tkWString;
    Result := '';
  finally
    oContext.Free;
  end;

end;

/// <summary>Reads the header captions of a tree through its published <c>Header.Columns</c>.</summary>
/// <param name="ATree">The tree.</param>
/// <returns>Captions by column index; empty when there are none or they cannot be reached.</returns>
function HeaderColumns( ATree: TObject ): TArray<string>;
begin

  Result := nil;

  var oHeader := GetObjectProp( ATree, 'Header' );
  if oHeader = nil then Exit;

  var oColumns := GetObjectProp( oHeader, 'Columns' );
  if not ( oColumns is TCollection ) then Exit;

  var oCollection := TCollection( oColumns );
  SetLength( Result, oCollection.Count );
  for var i := 0 to oCollection.Count - 1 do
    if IsPublishedProp( oCollection.Items[ i ], 'Text' ) then
      Result[ i ] := GetStrProp( oCollection.Items[ i ], 'Text' );

end;

/// <summary>The tree's own count of top-level nodes, the yardstick a read is checked against.</summary>
/// <param name="ATree">The tree.</param>
/// <returns>The count, or -1 when the tree does not publish <c>RootNodeCount</c>.</returns>
function RootNodeCount( ATree: TObject ): Integer;
begin

  if not IsPublishedProp( ATree, 'RootNodeCount' ) then Exit( -1 );

  Result := GetOrdProp( ATree, 'RootNodeCount' );

end;

{ ── TTreeTextReader ────────────────────────────────────────────────────── }

constructor TTreeTextReader.Create( ATree: TWinControl; APropInfo: PPropInfo; AWide: Boolean );
begin

  inherited Create;

  FTree    := ATree;
  FRowOf   := TDictionary<Pointer, Integer>.Create;
  FCells   := TObjectList<TStringList>.Create( True );
  FLevels  := TList<Integer>.Create;
  FContext := TRttiContext.Create;
  FindLevelMethod;

  FWide := AWide;
  if FWide then
  begin
    var mWide: TVstGetTextEventWide := HandleGetTextWide;
    FMine := TMethod( mWide );
  end
  else
  begin
    var mStr: TVstGetTextEventStr := HandleGetTextStr;
    FMine := TMethod( mStr );
  end;

  FOriginal := GetMethodProp( FTree, APropInfo );
  SetMethodProp( FTree, APropInfo, FMine );
  FPropInfo := APropInfo;

end;

destructor TTreeTextReader.Destroy;
begin

  // Normally already done by Walk. Done again here so an exception anywhere between Create and the
  // end of the walk can never leave a method pointer into this object behind after it is freed.
  Uninstall;

  FLevels.Free;
  FCells.Free;
  FRowOf.Free;
  FContext.Free;

  inherited;

end;

procedure TTreeTextReader.FindLevelMethod;
begin

  FLevelMethod := nil;

  var oType := FContext.GetType( FTree.ClassType );
  if oType = nil then Exit;

  var oMethod := oType.GetMethod( 'GetNodeLevel' );
  if oMethod = nil then Exit;

  var aParams := oMethod.GetParameters;
  if ( Length( aParams ) <> 1 ) or ( aParams[ 0 ].ParamType = nil ) or ( aParams[ 0 ].ParamType.TypeKind <> tkPointer ) then Exit;
  if ( oMethod.ReturnType = nil ) or ( oMethod.ReturnType.TypeKind <> tkInteger ) then Exit;

  FLevelMethod    := oMethod;
  FLevelParamType := aParams[ 0 ].ParamType.Handle;

end;

function TTreeTextReader.NodeLevel( ANode: Pointer ): Integer;
begin

  if ( FLevelMethod = nil ) or FLevelFailed then Exit( -1 );

  try
    var vNode: TValue;
    TValue.Make( @ANode, FLevelParamType, vNode );
    Result := Integer( FLevelMethod.Invoke( FTree, [ vNode ] ).AsOrdinal );
  except
    // Deliberately broad: this runs inside the host's paint, where anything raised becomes one
    // error dialog per painted row. A level is a nicety, so the first failure switches it off for
    // the rest of the read and the answer says so through LevelsUnavailable.
    on Exception do
    begin
      FLevelFailed := True;
      Result := -1;
    end;
  end;

end;

function TTreeTextReader.StillMine: Boolean;
begin

  var rCurrent := GetMethodProp( FTree, FPropInfo );
  Result := ( rCurrent.Code = FMine.Code ) and ( rCurrent.Data = FMine.Data );

end;

procedure TTreeTextReader.Uninstall;
begin

  if FPropInfo = nil then Exit;

  // Look before putting the original back: if something else took the event meanwhile, restoring
  // over it throws that away - but leaving this object's handler in place after it is freed would
  // be worse, so the original goes back regardless and Displaced lets the answer say so.
  FDisplaced := not StillMine;
  SetMethodProp( FTree, FPropInfo, FOriginal );
  FPropInfo := nil;

end;

procedure TTreeTextReader.HandleGetTextStr( ASender: TObject; ANode: Pointer; AColumn: Integer; ATextType: Byte;
  var ACellText: string );
begin

  // The real handler runs first and outside any guard, exactly as it would without us: what it
  // raises is the host's business, and it reaches the host as it always would.
  var mOriginal: TVstGetTextEventStr;
  TMethod( mOriginal ) := FOriginal;
  if Assigned( mOriginal ) then
    mOriginal( ASender, ANode, AColumn, ATextType, ACellText );

  RecordCell( ANode, AColumn, ATextType, ACellText );

end;

procedure TTreeTextReader.HandleGetTextWide( ASender: TObject; ANode: Pointer; AColumn: Integer; ATextType: Byte;
  var ACellText: WideString );
begin

  // As HandleGetTextStr. The conversion to string happens here, typed, so the BSTR is read as a
  // BSTR - its own length, no reference count - and never mistaken for a UnicodeString.
  var mOriginal: TVstGetTextEventWide;
  TMethod( mOriginal ) := FOriginal;
  if Assigned( mOriginal ) then
    mOriginal( ASender, ANode, AColumn, ATextType, ACellText );

  RecordCell( ANode, AColumn, ATextType, string( ACellText ) );

end;

procedure TTreeTextReader.RecordCell( ANode: Pointer; AColumn: Integer; ATextType: Byte; const AText: string );
begin

  // Nothing here may escape: this runs inside the host's paint, and the walk repaints many times,
  // so one exception would become one error dialog per paint. It is recorded for the answer instead.
  try
    if ATextType <> VST_TEXT_NORMAL then Exit;

    // A handler that writes into a string the caller pre-sized can leave an old tail behind a
    // terminator, so the text ends at the first #0.
    var sCell := AText;
    var iZero := Pos( #0, sCell );
    if iZero > 0 then
      sCell := Copy( sCell, 1, iZero - 1 );

    // -1 is VirtualTrees' NoColumn: a tree without header columns, which is one column here.
    var iColumn := AColumn;
    if iColumn < 0 then iColumn := 0;

    var iRow: Integer;
    if not FRowOf.TryGetValue( ANode, iRow ) then
    begin
      iRow := FCells.Add( TStringList.Create );
      FLevels.Add( NodeLevel( ANode ) );
      FRowOf.Add( ANode, iRow );
    end;

    // Assigned per column rather than appended: the walk paints some rows more than once - the
    // last page overlaps the one before, and restoring the scroll position paints again.
    var oRow := FCells[ iRow ];
    while oRow.Count <= iColumn do
      oRow.Add( '' );
    oRow[ iColumn ] := sCell;
  except
    on E: Exception do
      if FFailure = '' then
        FFailure := E.ClassName + ': ' + E.Message;
  end;

end;

function TTreeTextReader.Walk( AMaxRows: Integer ): Boolean;
begin

  var hTree := FTree.Handle;

  var fnVertPos: TFunc<Integer> :=
    function: Integer
    begin
      var rInfo: TScrollInfo;
      FillChar( rInfo, SizeOf( rInfo ), 0 );
      rInfo.cbSize := SizeOf( rInfo );
      rInfo.fMask  := SIF_POS;
      if GetScrollInfo( hTree, SB_VERT, rInfo ) then
        Result := rInfo.nPos
      else
        Result := 0;
    end;

  // Synchronous: UpdateWindow SENDS WM_PAINT, so by the time this returns every cell now on screen
  // has been asked for. InvalidateRect alone only queues one, and it would arrive after the answer.
  var prcPaintNow: TProc :=
    procedure
    begin
      InvalidateRect( hTree, nil, True );
      UpdateWindow( hTree );
    end;

  var iStarted := fnVertPos();

  // Only what is painted is asked about, so the tree is walked top to bottom a page at a time rather
  // than read once. Rows are keyed on the node, so the overlap between pages merges, and walking
  // downwards keeps them in display order.
  SendMessage( hTree, WM_VSCROLL, SB_TOP, 0 );
  prcPaintNow();

  var iSteps  := 0;
  var iBefore := 0;
  repeat
    if FCells.Count >= AMaxRows then Break;
    iBefore := fnVertPos();
    SendMessage( hTree, WM_VSCROLL, SB_PAGEDOWN, 0 );
    if fnVertPos() <> iBefore then
      prcPaintNow();
    Inc( iSteps );
  until ( fnVertPos() = iBefore ) or ( iSteps > WALK_MAX_STEPS );

  Result := ( FCells.Count < AMaxRows ) and ( fnVertPos() = iBefore ) and ( iSteps <= WALK_MAX_STEPS );

  // Back where the user had it, counted down from the top: WM_VSCROLL carries an absolute position
  // in 16 bits only, which a long enough tree would overflow.
  SendMessage( hTree, WM_VSCROLL, SB_TOP, 0 );
  iSteps := 0;
  while ( fnVertPos() < iStarted ) and ( iSteps <= WALK_MAX_STEPS ) do
  begin
    iBefore := fnVertPos();
    SendMessage( hTree, WM_VSCROLL, SB_LINEDOWN, 0 );
    if fnVertPos() = iBefore then Break;
    Inc( iSteps );
  end;
  prcPaintNow();

  // Out of the way as soon as the painting is done, not at some later Free.
  Uninstall;

end;

function TTreeTextReader.LevelsUnavailable: Boolean;
begin

  Result := ( FLevelMethod = nil ) or FLevelFailed;

end;

function TTreeTextReader.Rows: TArray<TTreeTextRow>;
begin

  SetLength( Result, FCells.Count );
  for var i := 0 to FCells.Count - 1 do
  begin
    var oCells := FCells[ i ];

    // A tree asks for every visible column whether or not it shows anything; drop the empty tail.
    var iLast := oCells.Count - 1;
    while ( iLast >= 0 ) and ( oCells[ iLast ] = '' ) do
      Dec( iLast );

    SetLength( Result[ i ].Cells, iLast + 1 );
    for var j := 0 to iLast do
      Result[ i ].Cells[ j ] := oCells[ j ];
    Result[ i ].Level := FLevels[ i ];
  end;

end;

{ ── entry point ────────────────────────────────────────────────────────── }

function ReadTreeText( AControl: TControl; AMaxRows: Integer ): TTreeTextResult;
begin

  if not IsVirtualTree( AControl ) then
    raise ETreeTextRefused.CreateCode( 'NotVirtualTree',
      Format( '%s is a %s, which is not a virtual tree', [ AControl.Name, AControl.ClassName ] ) );

  if not ( AControl is TWinControl ) or not TWinControl( AControl ).HandleAllocated then
    raise ETreeTextRefused.CreateCode( 'NoWindow',
      Format( '%s has no window, so it cannot be made to paint', [ AControl.Name ] ) );

  // Windows paints nothing into a window that is not on screen, and a virtual tree's text only
  // exists while it paints - so this would otherwise answer an empty list and blame nothing.
  // IsWindowVisible rather than Visible: a visible tree inside a hidden pane is just as unpainted.
  if not IsWindowVisible( TWinControl( AControl ).Handle ) then
    raise ETreeTextRefused.CreateCode( 'NotOnScreen',
      Format( '%s is not on screen, and only what is painted can be read. Show its window first, ' +
        'e.g. set Visible to true on the form that holds it', [ AControl.Name ] ) );

  var pProp := GetPropInfo( AControl, 'OnGetText' );
  if pProp = nil then
    raise ETreeTextRefused.CreateCode( 'NoGetText',
      Format( '%s has no OnGetText event, so its text cannot be read', [ AControl.Name ] ) );

  var bWide: Boolean;
  var sActual := SignatureMismatch( pProp, bWide );
  if sActual <> '' then
    raise ETreeTextRefused.CreateCode( 'SignatureMismatch',
      Format( '%s''s OnGetText is "%s", not the shape this reader stands in for, so hooking it could ' +
        'corrupt the text or crash the host; nothing was hooked', [ AControl.Name, sActual ] ) );

  if GetMethodProp( AControl, pProp ).Code = nil then
    raise ETreeTextRefused.CreateCode( 'NoGetText',
      Format( '%s has no OnGetText handler assigned, so nothing supplies its text', [ AControl.Name ] ) );

  var iMaxRows := AMaxRows;
  if iMaxRows < 1 then iMaxRows := 1;
  if iMaxRows > TREE_TEXT_MAX_ROWS_LIMIT then iMaxRows := TREE_TEXT_MAX_ROWS_LIMIT;

  Result.Columns   := HeaderColumns( AControl );
  Result.RootCount := RootNodeCount( AControl );

  var oNotes := TList<string>.Create;
  try
    var oReader := TTreeTextReader.Create( TWinControl( AControl ), pProp, bWide );
    try
      var bReachedEnd := oReader.Walk( iMaxRows );
      Result.Rows := oReader.Rows;

      Result.Complete := bReachedEnd and ( oReader.Failure = '' )
        and ( ( Result.RootCount < 0 ) or ( Length( Result.Rows ) >= Result.RootCount ) );

      if Length( Result.Rows ) >= iMaxRows then
        oNotes.Add( Format( 'stopped at the row limit of %d; pass a larger max to read further', [ iMaxRows ] ) )
      else if not bReachedEnd then
        oNotes.Add( 'the tree kept scrolling past the step limit, so the bottom was never reached' );

      // More rows than root nodes is normal - expanded children are rows too. Fewer is not.
      if ( Result.RootCount >= 0 ) and ( Length( Result.Rows ) < Result.RootCount ) then
        oNotes.Add( Format( 'only %d of the tree''s %d top-level rows were read; the rest never painted',
          [ Length( Result.Rows ), Result.RootCount ] ) );

      if oReader.Failure <> '' then
        oNotes.Add( 'recording a cell failed: ' + oReader.Failure );

      if oReader.LevelsUnavailable then
        oNotes.Add( 'the tree''s GetNodeLevel could not be called, so every row reports level -1' );

      if oReader.Displaced then
        oNotes.Add( 'something replaced OnGetText while it was being read; the handler that was there ' +
          'before has been put back over it' );

    finally
      oReader.Free;
    end;

    Result.Notes := oNotes.ToArray;
  finally
    oNotes.Free;
  end;

end;

end.
