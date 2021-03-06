function convert_to_text(fn, mat, varargin)

% extra input processing functions
prepend_input_processing = {};

nparams=length(varargin);

if 0 < mod(nparams, 2)
	error('Parameters must be specified as parameter/value pairs');
end
for i = 1:2:nparams
    nm = lower(varargin{i});
    switch nm
        case 'prepend_input_processing'
            if ischar(varargin{i+1})
                prepend_input_processing = varargin(i+1);
            else
                prepend_input_processing = varargin{i+1};
            end
        otherwise
            if ~exist(nm, 'var')
                error('Invalid parameter: %s.', nm);
            end
            eval([nm ' = varargin{i+1};']);
    end
end

%% LOAD NETWORK

% load network definition file
f = load(mat);

% default to same window size
if ~isfield(f, 'win_size')
    f.win_size = f.fft_size;
end

%% CHECKS

% FFT msut be a power of 2
if f.fft_size ~= 2^nextpow2(f.fft_size)
    error('Only FFT sizes that are a power of two are supported.');
end

% FFT must be longer than or equal to the window size
if f.win_size > f.fft_size
    error('The window size must be less than or equal to the FFT size.');
end

% handle weird spectrogram behavior
if 256 > f.fft_size
    warning('The spectrogram defaults to using an FFT size of 256. As a result, the provided FFT size will be ignored.');
    f.fft_size = 256;
end

%% WRITE TEXT FILE

% open file for writing
fh = fopen(fn, 'w');

fprintf(fh, '# AUTOMATICALLY GENERATED SYLLABLE DETECTOR CONFIGURATION\n');
fprintf(fh, 'samplingRate = %.1f\n', f.samplerate);
fprintf(fh, 'fourierLength = %d\n', f.fft_size);
fprintf(fh, 'windowLength = %d\n', f.win_size);
fprintf(fh, 'windowOverlap = %d\n', f.fft_size - f.fft_time_shift);

fprintf(fh, 'freqRange = %.1f, %.1f\n', f.freq_range(1), f.freq_range(end));
fprintf(fh, 'timeRange = %d\n', f.time_window_steps);

thresholds = sprintf('%.15g, ', reshape(f.trigger_thresholds, [], 1));
thresholds = thresholds(1:end - 2); % remove final comma
fprintf(fh, 'thresholds = %s\n', thresholds);

fprintf(fh, 'scaling = %s\n', f.scaling);

% build neural network

% input mapping
convert_processing_functions(fh, 'processInputs', f.net.input, prepend_input_processing);

% output mapping
convert_processing_functions(fh, 'processOutputs', f.net.output);

fprintf(fh, 'layers = %d\n', length(f.net.layers));

% layers
layers = {};
for i = 1:length(f.net.layers)
    % add layer
	name = sprintf('layer%d', i - 1);
	layers{i} = name;
    
    % check for non-consecutive weights
    if any(cellfun(@numel, f.net.LW(i, 1:length(f.net.layers) ~= i - 1)))
        error('Networks with only connections between consecutive layers supported.');
    end

	% get weights
	if 1 == i
		w = f.net.IW{i};
	else
		w = f.net.LW{i, i - 1};
		if 0 < length(f.net.IW{i})
			error('Found unexpected input weights for layer 1.');
		end
	end
	b = f.net.b{i};

	% add layer
	convert_layer(fh, name, f.net.layers{i}, w, b);
end

% close file handle
fclose(fh);

%% HELPER FUNCTIONS

function convert_processing_functions(fh, nm, put, pre, post)
    l = length(put.processFcns);
    
    if exist('pre', 'var')
    	l = l + length(pre);
    end
    if exist('post', 'var')
    	l = l + length(post);
    end
    
    if l == 0
        warning('Zero processing functions no longer results in linear normalization of input vectors.');
    end
    
    fprintf(fh, '%sCount = %d\n', nm, l);
    
    k = 0;
    
    if exist('pre', 'var')
        for j = 1:length(pre)
            % TODO: eventually support more than just strings here
            fprintf(fh, '%s%d.function = %s\n', nm, k, pre{j});
            k = k + 1;
        end
    end
    
    for j = 1:length(put.processFcns)
        switch put.processFcns{j}
            case 'mapminmax'
                offsets = sprintf('%.15g, ', put.processSettings{j}.xoffset);
                offsets = offsets(1:end - 2); % remove final comma
                gains = sprintf('%.15g, ', put.processSettings{j}.gain);
                gains = gains(1:end - 2); % remove final comma

                fprintf(fh, '%s%d.function = mapminmax\n', nm, k);
                fprintf(fh, '%s%d.xOffsets = %s\n', nm, k, offsets);
                fprintf(fh, '%s%d.gains = %s\n', nm, k, gains);
                fprintf(fh, '%s%d.yMin = %.15g\n', nm, k, put.processSettings{j}.ymin);
                
            case 'mapstd'
                offsets = sprintf('%.15g, ', put.processSettings{j}.xoffset);
                offsets = offsets(1:end - 2); % remove final comma
                gains = sprintf('%.15g, ', put.processSettings{j}.gain);
                gains = gains(1:end - 2); % remove final comma

                fprintf(fh, '%s%d.function = mapstd\n', nm, k);
                fprintf(fh, '%s%d.xOffsets = %s\n', nm, k, offsets);
                fprintf(fh, '%s%d.gains = %s\n', nm, k, gains);
                fprintf(fh, '%s%d.yMean = %.15g\n', nm, k, put.processSettings{j}.ymean);
                
            otherwise
                error('Invalid processing function: %s.', put.processFcns{j});
        end
        
        k = k + 1;
    end
    
    if exist('post', 'var')
        for j = 1:length(post)
            % TODO: eventually support more than just strings here
            fprintf(fh, '%s%d.function = %s\n', nm, k, post{j});
            k = k + 1;
        end
    end
end

function convert_layer(fh, nm, layer, w, b)
	if ~strcmp(layer.netInputFcn, 'netsum')
        error('Invalid input function: %s. Expected netsum.', layer.netInputFcn);
	end

    if strcmp(layer.transferFcn, 'tansig')
        tf = 'TanSig';
    elseif strcmp(layer.transferFcn, 'logsig')
        tf = 'LogSig';
    elseif strcmp(layer.transferFcn, 'purelin')
        tf = 'PureLin';
    elseif strcmp(layer.transferFcn, 'satlin')
        tf = 'SatLin';
    else
        error('Invalid transfer function: %s.', layer.transferFcn);
    end

    % have to flip weights before resizing to print row by row
	weights = sprintf('%.15g, ', reshape(w', [], 1));
    weights = weights(1:end - 2); % remove final comma
	biases = sprintf('%.15g, ', b);
    biases = biases(1:end - 2); % remove final comma

	fprintf(fh, '%s.inputs = %d\n', nm, size(w, 2));
    fprintf(fh, '%s.outputs = %d\n', nm, size(w, 1));
    fprintf(fh, '%s.weights = %s\n', nm, weights);
    fprintf(fh, '%s.biases = %s\n', nm, biases);
    fprintf(fh, '%s.transferFunction = %s\n', nm, tf);
end

end
