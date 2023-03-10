% Processes doric files to produce dF/F
% MGC 12/19/2022

% MGC 3/3/2023: Added option for number of ROIs and number of channels
%   also changed dF/F calculation to be more efficient (rolling baseline
%   computed in increments of 1 second and then interpolated, instead of for
%   every bin)

paths = struct;
paths.doric_data = 'D:\Doric\';
paths.save_data = 'D:\Doric\processed\';

opt = struct;
opt.sessions = {...
    'MC97_20230306_OdorLaser_FreeWater',...
    'MC98_20230306_OdorLaser_FreeWater',...
    };
opt.iti_offset = 5; % seconds past sync pulse onset to exclude from iti period
opt.smooth_signals = true; % if true, smooths before subtracting isosbestic
opt.smooth_sigma = 50; % in ms (only used if opt.smooth_signals = true);
opt.numROI = 1;
opt.RoiName = {'VS'};
opt.tdTom = false; % not implemented currently (tdTomato channel)

%% Get doric files
doric_files = dir(fullfile(paths.doric_data,'*.doric'));
doric_files = {doric_files.name}';


%% iterate over sessions
tic
for sesh_num = 1:numel(opt.sessions)

    session = opt.sessions{sesh_num};
    strsplit_this = strsplit(session,'_');
    mouse = strsplit_this{1};
    session_date = strsplit_this{2};
    
    fprintf('Session %d/%d: %s\n',sesh_num,numel(opt.sessions),session);
    
    doric_file = fullfile(paths.doric_data,doric_files(contains(doric_files,session)));
    doric_file = doric_file{1};

    % load photometry data
    dat = struct;
    dat.iso = cell(opt.numROI,1);
    dat.sig = cell(opt.numROI,1);
    dat.t_iso = h5read(doric_file,'/DataAcquisition/BFPD/ROISignals/Series0001/CAM1_EXC1/Time');
    dat.t_sig = h5read(doric_file,'/DataAcquisition/BFPD/ROISignals/Series0001/CAM1_EXC2/Time');
    for roiIdx = 1:opt.numROI
        dat.iso{roiIdx} = h5read(doric_file,...
            sprintf('/DataAcquisition/BFPD/ROISignals/Series0001/CAM1_EXC1/ROI0%d',roiIdx));
        dat.sig{roiIdx} = h5read(doric_file,...
            sprintf('/DataAcquisition/BFPD/ROISignals/Series0001/CAM1_EXC2/ROI0%d',roiIdx));
    end

    % load sync pulse data (Doric)
    dat_sync = struct;
    dat_sync.dio1 = h5read(doric_file,'/DataAcquisition/BFPD/Signals/Series0001/DigitalIO/DIO1');
    dat_sync.t = h5read(doric_file,'/DataAcquisition/BFPD/Signals/Series0001/DigitalIO/Time');
    
    %% extract sync pulse
    sync_idx = find(diff(dat_sync.dio1)==1)+1;
    synct = dat_sync.t(sync_idx);

    %% process photometry data
    %Convert to DeltaF/F

    iso_orig = cell(opt.numROI,1);
    F_orig = cell(opt.numROI,1);
    for roiIdx = 1:opt.numROI
        iso_orig{roiIdx} = deltaFoverF(dat.iso{roiIdx},dat.t_iso,synct,opt.iti_offset);
        F_orig{roiIdx} = deltaFoverF(dat.sig{roiIdx},dat.t_sig,synct,opt.iti_offset);
    end
    
    %% remove outliers
    for roiIdx = 1:opt.numROI
        iso_orig{roiIdx} = remove_outliers(iso_orig{roiIdx},0.01,99.99);
        F_orig{roiIdx} = remove_outliers(F_orig{roiIdx},0.01,99.99);
    end
    
    %% interpolate to same time scale
    t = min([dat.t_sig(1) dat.t_iso(1)]):0.001:max([dat.t_sig(end) dat.t_iso(end)]);
    iso = cell(opt.numROI,1);
    F = cell(opt.numROI,1);
    for roiIdx = 1:opt.numROI
        assert(numel(dat.t_iso)==numel(iso_orig{roiIdx}),'num time points mismatch');
        nkeep = min(numel(dat.t_iso),numel(iso_orig{roiIdx}));
        iso{roiIdx} = interp1(dat.t_iso(1:nkeep),iso_orig{roiIdx}(1:nkeep),t);
    
        assert(numel(dat.t_sig)==numel(F_orig{roiIdx}),'num time points mismatch');
        nkeep = min(numel(dat.t_sig),numel(F_orig{roiIdx}));
        F{roiIdx} = interp1(dat.t_sig(1:nkeep),F_orig{roiIdx}(1:nkeep),t);
    
    end
    
    %% get rid of some leading and ending nans
    for roiIdx = 1:opt.numROI
        iso{roiIdx} = clean_nans(iso{roiIdx},iso_orig{roiIdx}(1),iso_orig{roiIdx}(end));
        F{roiIdx} = clean_nans(F{roiIdx},F_orig{roiIdx}(1),F_orig{roiIdx}(end));
    end
    
    %% smooth signals    
    if opt.smooth_signals
        for roiIdx = 1:opt.numROI
            iso{roiIdx} = gauss_smooth(iso{roiIdx},opt.smooth_sigma);
            F{roiIdx} = gauss_smooth(F{roiIdx},opt.smooth_sigma);
        end
    end

    %% Regress out isosbestic channel
    iti_per = get_ITI_period(t,synct,opt.iti_offset);
    F_subtr = cell(opt.numROI,1);
    for roiIdx = 1:opt.numROI
        beta = polyfit(iso{roiIdx}(iti_per),F{roiIdx}(iti_per),1);
        pred = iso{roiIdx} * beta(1) + beta(2);
        F_subtr{roiIdx} = F{roiIdx} - pred;
    end
    
    %% Save processed data
    
    PhotData = struct;
    PhotData.t = t;
    PhotData.iso = iso;
    PhotData.F = F;
    PhotData.F_subtr = F_subtr;
    PhotData.RoiName = opt.RoiName;
    PhotData.dat_orig = dat;
    PhotData.synct = synct;
    PhotData.sync_idx = round(synct*1000);

    save(fullfile(paths.save_data,session),'PhotData');

end
toc

%% functions

function f0 = rolling_baseline(y,win,prct,stepsize)

f0 = nan(size(y));
sub_idx = 1:stepsize:numel(y);
for i = sub_idx
    idx_this = max(i-floor(win/2),1):min(numel(y),i+floor(win/2));
    f0(i) = prctile(y(idx_this),prct);
end
f0 = interp1(sub_idx,f0(sub_idx),1:numel(y))';
f0 = clean_nans(f0,f0(1),f0(max(sub_idx)));

end

function iti_per = get_ITI_period(t,synct,t_offset)

iti_per = true(size(t));
for i = 1:numel(synct)
    iti_per(t>=synct(i) & t<=synct(i)+t_offset) = false;
end

end

function F = deltaFoverF(y,t,synct,iti_offset)

% get ITI times
iti_per = get_ITI_period(t,synct,iti_offset);

% get f0 from a rolling window only including ITI
y_filt = y;
y_filt(~iti_per) = nan;
delt = median(diff(t));
f0 = rolling_baseline(y_filt,30/delt,10,round(1/delt));

% compute deltaF/F
F = (y-f0)./f0;

end

function F_clean = clean_nans(F,F1,Fend)
% clean leading and ending nans

% num leading nans
num_leading_nans = find(~isnan(F),1)-1;

% num ending nans
if isrow(F)
    num_ending_nans = find(~isnan(fliplr(F)),1)-1;
elseif iscolumn(F)
    num_ending_nans = find(~isnan(flipud(F)),1)-1;
end

F_clean = F;
F_clean(1:num_leading_nans) = F1;
F_clean(end-num_ending_nans+1:end) = Fend;

end

function y_new = remove_outliers(y,p_low,p_high)
% removes outliers using percentiles p_low and p_high

thresh_low = prctile(y,p_low);
thresh_high = prctile(y,p_high);
x = 1:numel(y);
keep = y>thresh_low & y<thresh_high;
y_new = interp1(x(keep),y(keep),x);

end