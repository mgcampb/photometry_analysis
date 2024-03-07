% Adds Bpod trial information to processed Doric data
% MGC 12/19/2022

% MGC 3/6/2023: updated for new round of experiments

paths = struct;
paths.doric_data = 'D:\Doric\processed\';
paths.save_data = 'D:\Doric\processed\';
paths.bpod_data = 'D:\Bpod_Data\';

opt = struct;
% opt.sessions = {...
%     'MC130_20240213_StimPatterns_FreeWater_withMaskingLight',...
%     'MC131_20240213_StimPatterns_FreeWater_withMaskingLight',...
%     'MC132_20240213_StimPatterns_FreeWater_withMaskingLight',...
% };
opt.sessions = {...
    'MC120_20240303_OdorLaser_FreeWater',...
    'MC121_20240303_OdorLaser_FreeWater',...
    'MC122_20240303_OdorLaser_FreeWater',...
    'MC123_20240303_OdorLaser_FreeWater',...
};

opt.bpod_protocol = 'OdorLaser_FreeWater';
% opt.bpod_protocol = 'OdorLaser_FreeWater_Extinction';
% opt.bpod_protocol = 'WaterDelivery_MultipleSizes';
% opt.bpod_protocol = 'StimPatterns_FreeWater';

%% Get doric files
doric_files = get_mat_files(paths.doric_data);

%% iterate over sessions
for sesh_num = 1:numel(opt.sessions)

    session = opt.sessions{sesh_num};
    strsplit_this = strsplit(session,'_');
    mouse = strsplit_this{1};
    session_date = strsplit_this{2};
    
    fprintf('Session %d/%d: %s\n',sesh_num,numel(opt.sessions),session);

    % load Doric data
    doric_file = fullfile(paths.doric_data,doric_files(contains(doric_files,session)));
    doric_file = doric_file{1};
    load(doric_file);
    
    % load Bpod data
    bpod_dir = fullfile(paths.bpod_data,mouse,opt.bpod_protocol,'Session Data');
    bpod_files = dir(fullfile(bpod_dir,'*.mat'));
    bpod_files = {bpod_files.name}';
    bpod_file = fullfile(bpod_dir,bpod_files(contains(bpod_files,session_date)));
    assert(numel(bpod_file)==1,'Either zero or more than one bpod file with this date');
    bpod_file = bpod_file{1};  
    load(bpod_file);
    
    
    %% make sure sync pulses align with bpod data
    
    if contains(doric_file,'OptoTagging') % for OdorLaser_FreeWater_OptoTagging sessions
        assert(corr(diff(PhotData.synct(41:250)),diff(SessionData.TrialStartTimestamp'))>0.99);
    else
        
        assert(corr(diff(PhotData.synct),diff(SessionData.TrialStartTimestamp'))>0.99);
    end

    % sub in Doric time stamps for Bpod session data
    if contains(doric_file,'OptoTagging') % for OdorLaser_FreeWater_OptoTagging sessions
        SessionData.TrialStartTimestamp = PhotData.synct(41:250);
    else
        SessionData.TrialStartTimestamp = PhotData.synct;
    end
    
    
    %% add lick timestamps (Port1In)
    
    lickts = [];
    for i = 1:SessionData.nTrials
        if isfield(SessionData.RawEvents.Trial{i}.Events,'Port1In')
            lickts_this = SessionData.RawEvents.Trial{i}.Events.Port1In;
            lickts = [lickts; lickts_this'+SessionData.TrialStartTimestamp(i)];
        end
    end
    SessionData.lickts = lickts;
    
    %% save
    save(doric_file,'SessionData','-append');
end