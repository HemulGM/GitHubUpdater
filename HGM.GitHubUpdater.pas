unit HGM.GitHubUpdater;

interface

uses
  System.Classes, System.SysUtils, System.Net.HttpClient, System.Threading,
  System.Messaging;

{$SCOPEDENUMS ON}

type
  TGitHubUpdater = class;

  TOnHaveUpdate = reference to function(const Ver, Url: string): Boolean;

  TOnUpdateError = reference to procedure(Sender: TGitHubUpdater; const Ver, Url: string);

  TMessageType = (NewUpdate, DoUpdate, UpdateError, DownloadError, CheckError, UpdateDone);

  TUpdaterMessage = class(TMessage)
  private
    FMessageType: TMessageType;
  public
    constructor Create(const MessageType: TMessageType);
    property MessageType: TMessageType read FMessageType;
  end;

  /// <summary>
  /// SelfReplace -
  /// </summary>
  TUpdaterMode = (SelfReplace, ManualUpdate);

  TGitHubUpdater = class
  private
    class var
      FInstance: TGitHubUpdater;
  private
    FTask: ITask;
    FUrl: string;
    FOnHaveUpdate: TOnHaveUpdate;
    FVersion: string;
    FNewVersion: string;
    FNewUrl: string;
    FBinName: string;
    FIsChecking: Boolean;
    FOnDownloading: TReceiveDataCallback;
    FOnDownloadError: TOnUpdateError;
    FMode: TUpdaterMode;
    FOnUpdateError: TOnUpdateError;
    FNewFileName: string;
    FLastError: string;
    procedure DownloadAndUpdateAsync;
    procedure DoNewUpdate;
    procedure DoUpdateDone;
    procedure DoDownloadError;
    procedure DoUpdateError;
    procedure SetOnHaveUpdate(const Value: TOnHaveUpdate);
    procedure SetUrl(const Value: string);
    procedure SetVersion(const Value: string);
    procedure SetBinName(const Value: string);
    procedure FOnReceiveDataDownload(const Sender: TObject; AContentLength: Int64; AReadCount: Int64; var AAbort: Boolean);
    procedure SetOnDownloading(const Value: TReceiveDataCallback);
    procedure SetOnDownloadError(const Value: TOnUpdateError);
    procedure SetMode(const Value: TUpdaterMode);
    procedure DoUpdate;
    procedure UpdateSelfReplace(const FileName: string);
    procedure UpdateSelfRestart(const FileName: string);
    procedure SetOnUpdateError(const Value: TOnUpdateError);
    procedure DoCheckError;
    procedure MessageListener(const Sender: TObject; const M: TMessage);
    procedure NotifyAction(const Action: TMessageType);
  public
    constructor Create;
    destructor Destroy; override;
    class function Instance: TGitHubUpdater; static;
    class destructor Destroy;
    procedure Check;
    property Url: string read FUrl write SetUrl; //https://github.com/HemulGM/ColorToStrNew
    property BinName: string read FBinName write SetBinName; //CTS.exe
    property Version: string read FVersion write SetVersion; //1.3
    property IsChecking: Boolean read FIsChecking;
    property Mode: TUpdaterMode read FMode write SetMode;
    property LastError: string read FLastError;
    property OnHaveUpdate: TOnHaveUpdate read FOnHaveUpdate write SetOnHaveUpdate;
    property OnDownloading: TReceiveDataCallback read FOnDownloading write SetOnDownloading;
    property OnDownloadError: TOnUpdateError read FOnDownloadError write SetOnDownloadError;
    property OnUpdateError: TOnUpdateError read FOnUpdateError write SetOnUpdateError;
  end;

implementation

uses
  System.IOUtils;

procedure TGitHubUpdater.DoNewUpdate;
begin
  if Assigned(FOnHaveUpdate) and (not FOnHaveUpdate(FNewVersion, FNewUrl)) then
    Exit;
  DownloadAndUpdateAsync;
end;

class function TGitHubUpdater.Instance: TGitHubUpdater;
begin
  if not Assigned(FInstance) then
    FInstance := TGitHubUpdater.Create;
  Result := FInstance;
end;

procedure TGitHubUpdater.MessageListener(const Sender: TObject; const M: TMessage);
var
  Msg: TUpdaterMessage absolute M;
begin
  case Msg.MessageType of
    TMessageType.NewUpdate:
      DoNewUpdate;
    TMessageType.DoUpdate:
      DoUpdate;
    TMessageType.UpdateError:
      DoUpdateError;
    TMessageType.DownloadError:
      DoDownloadError;
    TMessageType.UpdateDone:
      DoUpdateDone;
    TMessageType.CheckError:
      DoCheckError;
  end;
end;

constructor TGitHubUpdater.Create;
begin
  inherited;
  TMessageManager.DefaultManager.SubscribeToMessage(TUpdaterMessage, MessageListener);
  FIsChecking := False;
  FTask := nil;
end;

class destructor TGitHubUpdater.Destroy;
begin
  if Assigned(FInstance) then
    FInstance.Free;
end;

destructor TGitHubUpdater.Destroy;
begin
  TMessageManager.DefaultManager.Unsubscribe(TUpdaterMessage, MessageListener);
  if Assigned(FTask) then
    FTask.Cancel;
  inherited;
end;

procedure TGitHubUpdater.UpdateSelfReplace(const FileName: string);
var
  AppPath, OldAppPath: string;
begin
  try
    AppPath := ParamStr(0);
    OldAppPath := AppPath + '_old';
    if TFile.Exists(OldAppPath) then
      TFile.Delete(OldAppPath);
    TFile.Move(AppPath, OldAppPath);
    TFile.Move(FileName, AppPath);
  except
    //
  end;
  NotifyAction(TMessageType.UpdateDone);
end;

procedure TGitHubUpdater.NotifyAction(const Action: TMessageType);
begin
  TThread.Queue(nil,
    procedure
    begin
      TMessageManager.DefaultManager.SendMessage(Self, TUpdaterMessage.Create(Action), True);
    end);
end;

procedure TGitHubUpdater.UpdateSelfRestart(const FileName: string);
begin

end;

procedure TGitHubUpdater.DoUpdate;
begin
  case FMode of
    TUpdaterMode.SelfReplace:
      UpdateSelfReplace(FNewFileName);
    TUpdaterMode.ManualUpdate:
      UpdateSelfRestart(FNewFileName);
  end;
end;

procedure TGitHubUpdater.DownloadAndUpdateAsync;
begin
  //PanelWait.Visible := True;
  if Assigned(FTask) then
    Exit;
  FTask := TTask.Run(
    procedure
    var
      FNewFileName: string;
      HTTP: THTTPClient;
      Stream: TFileStream;
      Downloaded: Boolean;
    begin
      try
        FLastError := '';
        try
          FNewFileName := TPath.GetTempFileName;
          Stream := TFileStream.Create(FNewFileName, fmCreate);
          try
            HTTP := THTTPClient.Create;
            try
              HTTP.HandleRedirects := False;
              HTTP.OnReceiveData := FOnReceiveDataDownload;
              Downloaded := HTTP.Get(FUrl + '/releases/download/' + FNewVersion + '/' + FBinName, Stream).StatusCode = 200;
            finally
              HTTP.Free;
            end;
          finally
            Stream.Free;
          end;
        except
          on E: Exception do
          begin
            FLastError := E.Message;
            Downloaded := False;
          end;
        end;
        if Downloaded then
          NotifyAction(TMessageType.DoUpdate)
        else
          NotifyAction(TMessageType.DownloadError);
      finally
        FTask := nil;
      end;
    end);
end;

procedure TGitHubUpdater.FOnReceiveDataDownload(const Sender: TObject; AContentLength, AReadCount: Int64; var AAbort: Boolean);
begin
  if not Assigned(FTask) or (FTask.Status = TTaskStatus.Canceled) then
    AAbort := True;
  if Assigned(FOnDownloading) then
    FOnDownloading(Sender, AContentLength, AReadCount, AAbort);
end;

procedure TGitHubUpdater.SetBinName(const Value: string);
begin
  FBinName := Value;
end;

procedure TGitHubUpdater.SetMode(const Value: TUpdaterMode);
begin
  FMode := Value;
end;

procedure TGitHubUpdater.SetOnDownloadError(const Value: TOnUpdateError);
begin
  FOnDownloadError := Value;
end;

procedure TGitHubUpdater.SetOnDownloading(const Value: TReceiveDataCallback);
begin
  FOnDownloading := Value;
end;

procedure TGitHubUpdater.SetOnHaveUpdate(const Value: TOnHaveUpdate);
begin
  FOnHaveUpdate := Value;
end;

procedure TGitHubUpdater.SetOnUpdateError(const Value: TOnUpdateError);
begin
  FOnUpdateError := Value;
end;

procedure TGitHubUpdater.SetUrl(const Value: string);
begin
  FUrl := Value;
end;

procedure TGitHubUpdater.SetVersion(const Value: string);
begin
  FVersion := Value;
end;

procedure TGitHubUpdater.DoUpdateDone;
begin    {
  PanelWait.Visible := False;
  if TaskMessageDlg('Обновление успешно', 'Перезагрузить программу сейчас?', TMsgDlgType.mtConfirmation, [TMsgDlgBtn.mbYes, TMsgDlgBtn.mbNo], 0) = mrYes then
  begin
    Visible := False;
    ShellExecute(Application.Handle, 'open', PWideChar(ParamStr(0)), nil, nil, SW_NORMAL);
    Application.Terminate;
  end; }
end;

procedure TGitHubUpdater.DoUpdateError;
begin
  if Assigned(FOnUpdateError) then
    FOnUpdateError(Self, FNewVersion, FNewUrl);
end;

procedure TGitHubUpdater.DoDownloadError;
begin
  if Assigned(FOnDownloadError) then
    FOnDownloadError(Self, FNewVersion, FNewUrl);
end;

procedure TGitHubUpdater.DoCheckError;
begin
  if Assigned(FOnDownloadError) then
    FOnDownloadError(Self, FNewVersion, FNewUrl);
end;

procedure TGitHubUpdater.Check;
begin
  if Assigned(FTask) then
    Exit;
  FIsChecking := True;
  try
    FTask := TTask.Run(
      procedure
      var
        HTTP: THTTPClient;
        Response: IHTTPResponse;
        URI: TArray<string>;
        Done: Boolean;
      begin
        try
          Done := False;
          try
            HTTP := THTTPClient.Create;
            try
              HTTP.HandleRedirects := False;
              Response := HTTP.Head(FUrl + '/releases/latest');
              if Response.StatusCode = 200 then
              begin
                FNewUrl := Response.HeaderValue['Location'];
                URI := FNewUrl.Split(['/']);
                if Length(URI) > 0 then
                begin
                  FNewVersion := URI[High(URI)];
                  Done := True;
                end
                else
                  FLastError := 'Ошибка при парсинге информации о последнем релизе';
              end
              else
                FLastError := 'Ошибка при запросе информации о последнем релизе';
            finally
              HTTP.Free;
            end;
          except
            on E: Exception do
            begin
              FLastError := E.Message;
              Done := False;
            end;
          end;
          if Done then
          begin
            if FVersion <> FNewVersion then
              NotifyAction(TMessageType.NewUpdate)
          end
          else
            NotifyAction(TMessageType.CheckError)
        finally
          FTask := nil;
          FIsChecking := False;
        end;
      end);
  except
    FIsChecking := False;
  end;
end;

{ TUpdaterMessage }

constructor TUpdaterMessage.Create(const MessageType: TMessageType);
begin
  inherited Create;
  FMessageType := MessageType;
end;

end.

