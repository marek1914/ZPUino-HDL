library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.std_logic_unsigned.all;

use ieee.numeric_std.all;

library work;
use work.zpu_config.all;
use work.zpupkg.all;
use work.wishbonepkg.all;

--library UNISIM;
--use UNISIM.vcomponents.all;

entity zpuino_icache is
  port (
    wb_clk_i:       in std_logic;
    wb_rst_i:       in std_logic;

    valid:          out std_logic;
    data:           out std_logic_vector(wordSize-1 downto 0);
    address:        in std_logic_vector(maxAddrBit downto 0);
    strobe:         in std_logic;
    enable:         in std_logic;
    stall:          out std_logic;

    -- Master wishbone interface

    m_wb_ack_i:       in std_logic;
    m_wb_dat_i:       in std_logic_vector(wordSize-1 downto 0);
    m_wb_dat_o:       out std_logic_vector(wordSize-1 downto 0);
    m_wb_adr_o:       out std_logic_vector(maxAddrBit downto 0);
    m_wb_cyc_o:       out std_logic;
    m_wb_stb_o:       out std_logic;
    m_wb_stall_i:     in std_logic;
    m_wb_we_o:        out std_logic
  );
end zpuino_icache;

architecture behave of zpuino_icache is

  component generic_sp_ram is
  generic (
    address_bits: integer := 8;
    data_bits: integer := 32
  );
  port (
    clka:             in std_logic;
    ena:              in std_logic;
    wea:              in std_logic;
    addra:            in std_logic_vector(address_bits-1 downto 0);
    dia:              in std_logic_vector(data_bits-1 downto 0);
    doa:              out std_logic_vector(data_bits-1 downto 0)
  );
  end component;

  component generic_dp_ram is
  generic (
    address_bits: integer := 8;
    data_bits: integer := 32
  );
  port (
    clka:             in std_logic;
    ena:              in std_logic;
    wea:              in std_logic;
    addra:            in std_logic_vector(address_bits-1 downto 0);
    dia:              in std_logic_vector(data_bits-1 downto 0);
    doa:              out std_logic_vector(data_bits-1 downto 0);
    clkb:             in std_logic;
    enb:              in std_logic;
    web:              in std_logic;
    addrb:            in std_logic_vector(address_bits-1 downto 0);
    dib:              in std_logic_vector(data_bits-1 downto 0);
    dob:              out std_logic_vector(data_bits-1 downto 0)
  );
  end component generic_dp_ram;



  constant ADDRESS_HIGH: integer := 18;
  constant ADDRESS_LOW: integer := 0;
  constant CACHE_MAX_BITS: integer := 11; -- 2 Kb
  constant CACHE_LINE_SIZE_BITS: integer := 6; -- 64 bytes
  constant CACHE_LINE_ID_BITS: integer := CACHE_MAX_BITS-CACHE_LINE_SIZE_BITS;

-- memory max width: 19 bits (18 downto 0)
-- cache line size: 64 bytes
-- cache lines: 128



  alias line: std_logic_vector(CACHE_LINE_ID_BITS-1 downto 0)
    is address(CACHE_MAX_BITS-1 downto CACHE_LINE_SIZE_BITS);

  alias line_offset: std_logic_vector(CACHE_LINE_SIZE_BITS-1 downto 2)
    is address(CACHE_LINE_SIZE_BITS-1 downto 2);

  alias tag: std_logic_vector(ADDRESS_HIGH-CACHE_MAX_BITS-1 downto 0)
    is address(ADDRESS_HIGH-1 downto CACHE_MAX_BITS);

  signal ctag: std_logic_vector(tag'RANGE);
  --signal valid: std_logic;

  type validmemtype is ARRAY(0 to (2**line'LENGTH)-1) of std_logic;
  shared variable valid_mem: validmemtype;

  signal tag_mem_wen: std_logic;
  signal miss: std_logic;
  signal ack: std_logic;

  signal fill_end: std_logic;
  signal fill_end_q: std_logic;
  signal fill_end_q_q: std_logic;
  signal offcnt: unsigned(line_offset'HIGH+1 downto 2);
  signal offcnt_q: unsigned(line_offset'HIGH+1 downto 2);

  signal tag_match: std_logic;
  signal save_addr: std_logic_vector(address'RANGE);
  signal cyc, cyc_q: std_logic;
  signal cache_addr_read,cache_addr_write:
    std_logic_vector(CACHE_MAX_BITS-1 downto 2);

  alias tag_save: std_logic_vector(ADDRESS_HIGH-CACHE_MAX_BITS-1 downto 0)
    is save_addr(ADDRESS_HIGH-1 downto CACHE_MAX_BITS);

  alias line_save: std_logic_vector(CACHE_LINE_ID_BITS-1 downto 0)
    is save_addr(CACHE_MAX_BITS-1 downto CACHE_LINE_SIZE_BITS);

  signal access_i: std_logic;
  signal access_q: std_logic;
  signal stall_i, valid_i: std_logic;
  signal busy: std_logic;
  signal hit: std_logic;
  signal tag_mem_enable: std_logic;

  type state_type is (
    running,
    filling,
    ending
  );

  signal state: state_type;
  signal fill_success: std_logic;

begin

  tagmem: generic_dp_ram
  generic map (
    address_bits  => line'LENGTH,
    data_bits     => ctag'LENGTH
  )
  port map (
    clka      => wb_clk_i,
    ena       => tag_mem_enable,
    wea       => '0',
    addra     => line,
    dia       => tag,
    doa       => ctag,

    clkb      => wb_clk_i,
    enb       => '1',
    web       => tag_mem_wen,
    addrb     => line_save,
    dib       => tag_save,
    dob       => open
  );

  tag_match <= '1' when ctag=tag else '0';
  stall <= stall_i;
  valid <= ack;
  tag_mem_enable <= access_i and enable;

  -- Valid mem
  process(wb_clk_i)
    variable index: integer;
  begin
    if rising_edge(wb_clk_i) then
      if wb_rst_i='1' then
        for i in 0 to (valid_mem'LENGTH)-1 loop
          valid_mem(i) := '0';
        end loop;
      else
        index := conv_integer(line_save);
        if tag_mem_wen='1' then
          valid_mem(index) := fill_success;
        end if;
      end if;
      valid_i <= valid_mem(conv_integer(line_save));
    end if;
  end process;

  -- Address save
  process(wb_clk_i)
  begin
    if rising_edge(wb_clk_i) then
      if stall_i='0' and enable='1' then
        save_addr <= address;
      end if;
      fill_end_q <= fill_end;
      fill_end_q_q <= fill_end_q;
    end if;
  end process;

  cachemem: generic_dp_ram
  generic map (
    address_bits => cache_addr_read'LENGTH,
    data_bits => 32
  )
  port map (
    clka      => wb_clk_i,
    ena       => enable,
    wea       => '0',
    addra     => cache_addr_read,
    dia       => (others => '0'),
    doa       => data,

    clkb      => wb_clk_i,
    enb       => '1',
    web       => m_wb_ack_i,
    addrb     => cache_addr_write,
    dib       => m_wb_dat_i,
    dob       => open
  );

  process(wb_clk_i)
  begin
    if rising_edge(wb_clk_i) then
      if wb_rst_i='1' then
        access_q<='0';
      else
        if busy='0' and enable='1' then
          access_q <= access_i;
        end if;
      end if;
    end if;
  end process;


  -- offset counter
  process(wb_clk_i)
  begin
    if rising_edge(wb_clk_i) then
  --    if offcnt(offcnt'HIGH)='1' or wb_rst_i='1' then  -- this is probably ! ack.
  --      offcnt <= (others => '0');
  --    else
  --     if m_wb_stall_i='0' and cyc='1' then
  --        offcnt <= offcnt + 1;
 --       end if;
  --    end if;
      offcnt_q <= offcnt;
    end if;
  end process;


  --fill_success<=fill_end;

  process(wb_clk_i)
  begin
    if rising_edge(wb_clk_i) then
      if wb_rst_i='1' then
        state <= running;
      else
        busy <= '0';
        
        case state is
          when running =>
            if access_q='1' then
              if miss='1' then
                state <= filling;
                offcnt <= (others => '0');
                fill_success<='1';
              end if;
            end if;
          when filling =>
            busy<='1';
            if m_wb_stall_i='0' then
              offcnt <= offcnt + 1;
            end if;
            -- Abort
            if enable='0' or strobe='0' then
              --offcnt <= (others => '0');
              --state <= running;
              --fill_success<='0';
              -- fill_success will be zero here, so will invalidate cache line
            end if;
            if fill_end='1' then
              state <= ending;
              offcnt <= (others => '0');
            end if;
          when ending =>
            busy<='1';
            state <= running;
        end case;
      end if;
    end if;
  end process;


  access_i <= strobe;
  m_wb_cyc_o <= cyc;
  m_wb_stb_o <= cyc;

  process(miss,tag_mem_wen,strobe,enable,access_q,busy)
  begin
    if busy='1' then
      cyc<='1';
    else
      if miss='1' and tag_mem_wen='0' and access_q='1' and enable='1' then --and strobe='1' and enable='1'
        cyc <= '1';
      else
        cyc <= '0';
      end if;
    end if;
  end process;


  m_wb_we_o<='0';

  hit <= '1' when tag_match='1' and valid_i='1' and access_q='1' else '0';

  ack <= hit when busy='0' else fill_end_q_q;

  fill_end<=offcnt(offcnt'HIGH);

  miss <= not ack;

  tag_mem_wen <= offcnt(offcnt'HIGH);

  cache_addr_read <= line & line_offset when stall_i='0' else save_addr(CACHE_MAX_BITS-1 downto 2);

  cache_addr_write <= line_save & std_logic_vector(offcnt_q(offcnt_q'HIGH-1 downto 2));

  stall_i <= miss when access_q='1' else busy;

--  process(wb_clk_i)
--  begin
--    if rising_edge(wb_clk_i) then
--      if wb_rst_i='1' then
--        busy<='0';
--      else
--        if fill_end_q='1' then
--          busy<='0';
--        elsif cyc='1' then
--          busy<='1';
--        end if;
--      end if;
--    end if;
--  end process;

  m_wb_adr_o(maxAddrBit downto CACHE_LINE_SIZE_BITS) <= save_addr(maxAddrBit downto CACHE_LINE_SIZE_BITS);
  m_wb_adr_o(CACHE_LINE_SIZE_BITS-1 downto 2) <= std_logic_vector(offcnt(CACHE_LINE_SIZE_BITS-1 downto 2));

end behave;