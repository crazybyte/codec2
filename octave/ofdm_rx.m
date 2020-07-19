% ofdm_rx.m
% David Rowe May 2018
%
% OFDM file based , uncoded rx to unit test core OFDM modem.  See also
% ofdm_ldpc_rx which includes LDPC and interleaving, and ofdm_demod.c


function ofdm_rx(filename, mode="700D", error_pattern_filename)
  ofdm_lib;
  more off;

  dpsk = 0;
  if strcmp(mode,"700D-DPSK")
    mode = "700D"; dpsk = 1;
  end
  if strcmp(mode,"2020-DPSK")
    mode = "2020"; dpsk = 1;
  end
  
  % init modem

  config = ofdm_init_mode(mode);
  states = ofdm_init(config);
  print_config(states);
  ofdm_load_const;
  states.verbose = 0;
  states.dpsk=dpsk;
  
  % load real samples from file

  Ascale = states.amp_scale/2; % as input is a real valued signal
  frx=fopen(filename,"rb"); rx = fread(frx, Inf, "short")/Ascale; fclose(frx);
  Nsam = length(rx); Nframes = floor(Nsam/Nsamperframe);
  prx = 1;

  % OK re-generate tx frame for BER calcs

  tx_bits = create_ldpc_test_frame(states, coded_frame=0);
  
  % init logs and BER stats

  rx_np_log = []; timing_est_log = []; delta_t_log = []; foff_est_hz_log = [];
  phase_est_pilot_log = []; sig_var_log = []; noise_var_log = []; channel_est_log = [];
  Terrs = Tbits = Terrs_coded = Tbits_coded = Tpackets = Tpacketerrs = 0;
  packet_count = frame_count = 0;
  Nerrs_coded_log = Nerrs_log = [];
  error_positions = [];

  % 'prime' rx buf to get correct coarse timing (for now)

  prx = 1;
  nin = Nsamperframe+2*(M+Ncp);
  %states.rxbuf(Nrxbuf-nin+1:Nrxbuf) = rx(prx:nin);
  %prx += nin;
  
  states.verbose = 1;

  Nsymsperpacket = Nbitsperpacket/bps; Nsymsperframe = Nbitsperframe/bps;
  rx_syms = zeros(1,Nsymsperpacket); rx_amps = zeros(1,Nsymsperpacket);
  Nerrs = 0; rx_uw = zeros(1,states.Nuwbits);
  
  % main loop ----------------------------------------------------------------

  for f=1:Nframes

    % insert samples at end of buffer, set to zero if no samples
    % available to disable phase estimation on future pilots on last
    % frame of simulation

    lnew = min(Nsam-prx,states.nin);
    rxbuf_in = zeros(1,states.nin);

    if lnew
      rxbuf_in(1:lnew) = rx(prx:prx+lnew-1);
    end
    prx += states.nin;
 
    if states.verbose
      printf("f: %3d nin: %4d st: %-6s ", f, states.nin, states.sync_state);
    end
    
    if strcmp(states.sync_state,'search') 
      [timing_valid states] = ofdm_sync_search(states, rxbuf_in);
    end
    
    if strcmp(states.sync_state,'synced') || strcmp(states.sync_state,'trial')

      % accumulate a buffer of data symbols for this packet
      rx_syms(1:end-Nsymsperframe) = rx_syms(Nsymsperframe+1:end);
      rx_amps(1:end-Nsymsperframe) = rx_amps(Nsymsperframe+1:end);
      [states rx_bits aphase_est_pilot_log arx_np arx_amp] = ofdm_demod(states, rxbuf_in);
      rx_syms(end-Nsymsperframe+1:end) = arx_np;
      rx_amps(end-Nsymsperframe+1:end) = arx_amp;

      rx_uw = extract_uw(states, rx_syms(end-Nuwframes*Nsymsperframe+1:end));
      
      % We need the full packet of symbols before disassmbling and checking for bit errors
      if states.modem_frame == (states.Np-1)
        rx_bits = zeros(1,Nbitsperpacket);
        for s=1:Nsymsperpacket
          if bps == 2
             rx_bits(bps*(s-1)+1:bps*s) = qpsk_demod(rx_syms(s));
          elseif bps == 4
             rx_bits(bps*(s-1)+1:bps*s) = qam16_demod(states.qam16,rx_syms(s)*exp(j*pi/4));
          end
        end

        errors = xor(tx_bits, rx_bits);
        Nerrs = sum(errors);
        Nerrs_log = [Nerrs_log Nerrs];
        Terrs += Nerrs;
        Tbits += Nbitsperpacket;
        packet_count++;
      end
      
      % we are in sync so log states

      rx_np_log = [rx_np_log arx_np];
      timing_est_log = [timing_est_log states.timing_est];
      delta_t_log = [delta_t_log states.delta_t];
      foff_est_hz_log = [foff_est_hz_log states.foff_est_hz];
      phase_est_pilot_log = [phase_est_pilot_log; aphase_est_pilot_log];
      sig_var_log = [sig_var_log states.sig_var];
      noise_var_log = [noise_var_log states.noise_var];
      channel_est_log = [channel_est_log; states.achannel_est_rect];
      
      frame_count++;
    end
    
    if strcmp(mode,"datac1") || strcmp(mode,"datac2") || strcmp(mode,"datac3") || strcmp(mode,"qam16")
      states = sync_state_machine2(states, rx_uw);
    else
      states = sync_state_machine(states, rx_uw);
    end

    if states.verbose
      if strcmp(states.last_sync_state,'synced') || strcmp(states.last_sync_state,'trial')
        printf("euw: %2d %d mf: %2d pbw: %s eraw: %3d foff: %4.1f",
                states.uw_errors, states.sync_counter, states.modem_frame, states.phase_est_bandwidth(1),
                Nerrs, states.foff_est_hz);
      end
      printf("\n");
    end

    % act on any events returned by state machine
    
    if states.sync_start
      Nerrs_log = [];
      Terrs = Tbits = frame_count = 0;
      rx_np_log = [];
      sig_var_log = []; noise_var_log = [];
    end
  end

  printf("\nBER..: %5.4f Tbits: %5d Terrs: %5d\n", Terrs/(Tbits+1E-12), Tbits, Terrs);

  % If we have enough frames, calc BER discarding first few frames where freq
  % offset is adjusting

  Ndiscard = 20;
  if packet_count > Ndiscard
    Terrs -= sum(Nerrs_log(1:Ndiscard)); Tbits -= Ndiscard*Nbitsperframe;
    printf("BER2.: %5.4f Tbits: %5d Terrs: %5d\n", Terrs/Tbits, Tbits, Terrs);
  end

  %EsNo_est = mean(sig_var_log(floor(end/2):end))/mean(noise_var_log(floor(end/2):end));
  EsNo_est = mean(sig_var_log)/mean(noise_var_log);
  EsNo_estdB = 10*log10(EsNo_est);
  SNR_estdB = EsNo_estdB + 10*log10(Nc*Rs*bps/3000);
  printf("Packets: %3d Es/No est dB: % -4.1f SNR3k: %3.2f %f %f\n",
         packet_count, EsNo_estdB, SNR_estdB, mean(sig_var_log), mean(noise_var_log));
  
  figure(1); clf; 
  %plot(rx_np_log,'+');
  plot(exp(j*pi/4)*rx_np_log(floor(end/2):end),'+');
  mx = 2*max(abs(rx_np_log));
  axis([-mx mx -mx mx]);
  title('Scatter');
  
  figure(2); clf;
  plot(phase_est_pilot_log(:,2:Nc),'g+', 'markersize', 5); 
  title('Phase est');
  axis([1 length(phase_est_pilot_log) -pi pi]);  

  figure(3); clf;
  subplot(211)
  stem(delta_t_log)
  title('delta t');
  subplot(212)
  plot(timing_est_log);
  title('timing est');

  figure(4); clf;
  plot(foff_est_hz_log)
  mx = max(abs(foff_est_hz_log))+1;
  axis([1 max(Nframes,2) -mx mx]);
  title('Fine Freq');
  ylabel('Hz')

  figure(5); clf;
  stem(Nerrs_log);
  title('Errors/modem frame')
  axis([1 length(Nerrs_log) 0 Nbitsperframe*rate/2]);

  figure(6); clf;
  plot(10*log10(sig_var_log),'b;Es;');
  hold on;
  plot(10*log10(noise_var_log),'r;No;');
  snr_estdB = 10*log10(sig_var_log) - 10*log10(noise_var_log) + 10*log10(Nc*Rs/3000);
  snr_smoothed_estdB = filter(0.1,[1 -0.9],snr_estdB);
  plot(snr_smoothed_estdB,'g;SNR3k;');
  hold off;
  title('Signal and Noise Power estimates');

  if nargin == 3
    fep = fopen(error_pattern_filename, "wb");
    fwrite(fep, error_positions, "short");
    fclose(fep);
  end
endfunction
